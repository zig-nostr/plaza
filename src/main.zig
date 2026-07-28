//! Plaza, the flagship native Nostr client.
//!
//! A first run opens a welcome screen with three ways in: create a fresh
//! identity, paste an existing `nsec` to import a key, or paste a `bunker://`
//! link to connect an external signer (Signet) over NIP-46 so the secret key
//! never enters Plaza. The choice is persisted as a session, so a returning user
//! is signed straight back in (a local key from disk, or a silent bunker
//! reconnect). A Settings screen shows who you are signed in as, lets a local
//! user back up their secret key, and logs out without locking anyone in: your
//! key is always yours to copy and take elsewhere.
//!
//! Signed in, you land in a follow-based feed seeded by a curated starter pack
//! (the `starter_pack` authors). Composing signs a kind:1 (locally, or by a
//! `sign_event` round-trip to the bunker), which is stored locally and published
//! to the pool. The feed runs as a pool (each relay on its own thread ingesting
//! into the one shared store, deduped by event id), scoped to the follow set,
//! rendered from disk on a timer, all in one process. Real names (kind:0
//! profiles) and NIP-65 outbox routing come in the milestones ahead.
//!
//! The static screens live in `onboarding.native` and `settings.native`; the
//! feed is a Zig view (inline images need a runtime image reference the markup
//! grammar does not carry). This file is the logic.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const plaza_icons = @import("plaza_icons.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
// A desktop window sized for the redesign's centered reading column: the feed
// content is a fixed 620px column, so the window opens wide enough to seat it
// with real margin on either side, and extra width past that becomes margin,
// never a longer line. Wider than tall: a reading column wants breathing room,
// not a tower.
pub const window_width: f32 = 760;
pub const window_height: f32 = 540;
const feed_column_width: f32 = 620;
// The thread's reading column matches the feed's: both are virtualLists now,
// which reserve the same scrollbar gutter, so the two screens share one column
// width and one left edge.
const thread_column_width: f32 = feed_column_width;

// The relay pool this milestone dials, and how many recent notes to keep on
// screen. Each relay runs on its own thread and ingests into the one shared
// store, which dedupes by event id. NIP-65 outbox routing (reading each author
// from their own write relays) needs a follow list, so it arrives with a later
// milestone; here a fixed pool is the relay engine.
const relays = [_][]const u8{
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://relay.nostr.band",
    "wss://relay.snort.social",
};

// The curated starter pack a newcomer follows on first run: a handful of
// well-known, active accounts so the feed is alive from the first second. The
// feed is scoped to these authors (plus the user's own notes); follow
// management and NIP-51 lists come later. Pubkeys are hex, decoded to bytes at
// comptime.
const starter_pack_hex = [_][]const u8{
    "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", // fiatjaf
    "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2", // jack
    "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245", // jb55
    "04c915daefee38317fa734444acee390a8269fe5810b2241e5e6dd343dfbecc9", // ODELL
    "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93", // gigi
    "84dee6e676e5bb67b4ad4e042cf70cbd8681155db535942fcc6a0533858a7240", // Snowden
    "fa984bd7dbb282f07e16e7ae87b26a2a7b9b90b7246a44771f0cf5ae58018f52", // Vitor (Amethyst)
    "eab0e756d32b80bcd464f3d844b8040303075a13eabc3599a762c9ac7ab91f4f", // hodlbod
    "460c25e682fda7832b52d1f22d3d22b3176d972f60dcdc3212ed8c92ef85065c", // Lyn Alden
};
const starter_pack = blk: {
    var pks: [starter_pack_hex.len][32]u8 = undefined;
    for (starter_pack_hex, 0..) |h, i| {
        _ = std.fmt.hexToBytes(&pks[i], h) catch unreachable;
    }
    break :blk pks;
};

// How many notes the feed can hold, and how many it asks the store for at
// first. The list is windowed, so holding more costs memory, not frames; the
// query grows a page at a time as the reader reaches the end.
const feed_capacity = 300;
const feed_page = 60;
// A thread's replies are cached in the model (pressable, their pictures
// fetched), so this bounds that buffer. `thread_depth_max` bounds the
// open-as-a-sub-thread back-stack, and its ceiling is the SDK's virtual-window
// budget: every mounted level is a virtualList and the SDK tracks at most 8
// virtual windows per build (excess lists are silently dropped, and the LAST
// built (the visible thread) is the one that breaks). The feed plus six
// ancestors plus the current level is exactly eight.
const thread_reply_cap = 100;
pub const thread_depth_max = 6;
// How long a thread shows loading skeletons before giving up if the reply fetch
// never signals completion (a relay that never sends EOSE), so a reply-less note
// never stalls under skeletons forever.
const thread_loading_grace_s = 6;
// How much of a note's text is stored. A long note is collapsed in the feed to
// `note_collapse_chars` with a "Show more" that reveals the rest, up to this cap
// (a kind:1 past it is truncated: long-form is kind:30023, not a note).
const note_content_cap = 1024;
const note_collapse_chars = 300;
// How many loaded notes each relay watches for engagement. Bounded so the
// `#e` filter stays a size relays accept; covers the feed's first screens.
const engagement_watch_cap = 128;
// The composer's fixed text capacity. Comfortably longer than a typical note;
// the display buffer (`Note.content_buf`) truncates for rendering, but the
// published event carries the full draft.
const compose_capacity = 512;
const refresh_timer_key: u64 = 1;
const refresh_interval_ms: u64 = 1_000;
// Wanted-profile fetching runs on its own cadence, decoupled from the view
// refresh: an author's name and avatar do not need per-second freshness, and a
// separate engine timer is the seam a future data-plane extraction cuts along.
const profile_timer_key: u64 = 3;
const profile_interval_ms: u64 = 2_000;
// The app version shown in Settings. Keep in step with app.zon's `.version`.
const plaza_version = "0.1.0";
// Owner-only permissions for the files holding secrets. POSIX gets 0600;
// Windows has no mode bits (its permissions are file ATTRIBUTES), so it takes
// the default there and inherits the profile directory's access control.
const secret_file_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    std.Io.File.Permissions.fromMode(0o600);
// Effect keys for the two Settings clipboard copies (npub, nsec). Clipboard
// effects share the effect key space, so these stay distinct from the timer key.
const copy_npub_key: u64 = 100;
const copy_nsec_key: u64 = 101;
const copy_nevent_key: u64 = 103;
// Image fetches use effect keys `<base> + slot`, kept clear of the timer and
// clipboard keys above.
const avatar_fetch_key_base: u64 = 1000;
const media_fetch_key_base: u64 = 2000;
// NIP-05 well-known verification fetches, keyed `<base> + profile slot`.
const nip05_fetch_key_base: u64 = 3000;
const link_fetch_key_base: u64 = 4000;
const open_url_key: u64 = 102;

// The profile cache holds display names and avatars keyed by pubkey. It must be
// larger than the biggest on-screen author set marked in a single avatar pass
// (a full thread: the active user + the root + up to `thread_reply_cap` replies)
// with headroom for recently-seen authors, so the mark pass never has to evict
// an author it just marked. Names are cheap; only avatars are slot-bound.
const profile_cap = thread_reply_cap + 60;

comptime {
    // The avatar pass marks the whole on-screen author set (active user + a
    // thread's root and every reply) before lending ids, so the cache MUST hold
    // that set at once; otherwise the mark loop evicts an author it just marked
    // and the cache thrashes every tick (an avatar-review finding). Keep the
    // headroom generous so recently-seen authors survive too.
    if (profile_cap < thread_reply_cap + 2) @compileError("profile_cap must exceed a thread's author set");
}
// The canvas image registry has 16 slots for the whole app, so avatars and feed
// media split it. The avatar share covers every author the follow feed can show
// (the starter pack plus the user), so nobody in the feed is stuck on initials;
// feed images take the rest through a small LRU. A mention-only cache entry,
// past the avatar budget, renders initials.
//
// THE WHOLE-APP IMAGE BUDGET. The registry is hard-capped at
// `image_registry_slots` registrations of at most 1 MiB of DECODED pixels each
// (exactly 512x512 RGBA8); an oversized registration fails with
// `error.ImageTooLarge` and a 17th with `error.ImageRegistryFull`. It is the
// tightest resource in the app, so the target architecture is stated here before
// the consumers that need it arrive:
//
//   ONE LRU over all 16 slots, serving every image kind (avatars, feed media,
//   profile banners) from a single mark-then-lend pass: mark the whole on-screen
//   image set in READING ORDER, then lend a free slot or evict the
//   least-recently-seen one. Consumers differ only in their DECODE ceiling
//   (an avatar at `avatar_px`, feed media inside the `media_px` box, a banner
//   downscaled under the 1 MiB cap), never in a reserved share of the slots.
//   Reserved shares are what strand capacity: a profile screen wants a banner
//   and many avatars and no feed media at all, and a fixed media share would
//   sit idle while authors fall back to initials.
//
// Two rules hold under any allocation:
//   - Anything larger than an avatar is downscaled through the vendored stb path
//     before registration, bounded as a BOX and not just a width (a 512-wide
//     image that happens to be tall still blows the decoded cap). A profile
//     banner at its drawn 660x132 is 1.39 MB of RGBA at 2x, so it must come down
//     first, the way feed media already does.
//   - A placeholder and the image it stands in for SHARE one slot: a blurhash
//     preview registers into the very slot its full image overwrites in place, so
//     a screen of loading rows can never double-claim capacity. Peak media
//     consumption stays at `max_media_images` as a POLICY cap inside the shared
//     pool, not as a reservation.
//   - Link previews use letter tiles, drawn as text, so they cost no slots.
//
// WHAT THE CODE DOES TODAY, and the deviation: the two fixed pools below predate
// this note and still stand, because unifying them now would mean writing the
// allocator against imagined callers. The unification lands with the first
// consumer that actually crosses the pools (the blurhash placeholder, then the
// profile banner), and the assertion below keeps the interim split honest.
pub const image_registry_slots = native_sdk.max_registered_canvas_images;
/// The redesign's note-row metrics. The avatar size is load-bearing: the
/// identity block beside it is pinned to the same height, so the name and handle
/// sit against the disc's top and bottom edges.
pub const avatar_size: f32 = 36;
pub const row_pad_top: f32 = 12;
pub const row_pad_side: f32 = 16;
pub const row_pad_bottom: f32 = 14;
pub const avatar_to_text_gap: f32 = 12;
/// The chrome's horizontal inset: the guest banner, the scope line and the feed
/// rows all hang off this one edge.
const chrome_inset: f32 = 16;
const rail_gap: f32 = 8;
/// The scope title (13.5) and the mono metadata register (10.5), as multipliers
/// of the 14.5 body, since the size enum only steps by one.
const scope_title_scale: f32 = 13.5 / 14.5;
const mono_meta_scale: f32 = 10.5 / 14.5;
/// The status bar's 11.5px register, and the menus' 12 / 12.5 / 11 / 9.5.
const status_scale: f32 = 11.5 / 14.5;
const menu_scale: f32 = 12.5 / 14.5;
const mono_row_scale: f32 = 11.5 / 14.5;
const mono_hint_scale: f32 = 11.0 / 14.5;
const mono_badge_scale: f32 = 9.5 / 14.5;
/// The focal note's own register (16.5 against the 14.5 body), the stats line's
/// 12.5, and the 4px each thread block sits in from the reading column's edge.
const focal_body_scale: f32 = 16.5 / 14.5;
const stat_scale: f32 = 12.5 / 14.5;
const thread_inset: f32 = 4;
/// The same number, for a test that has to know where a row's disc lands.
pub const thread_inset_for_test: f32 = thread_inset;
/// The focal note minus its body: the 16 above, the identity block, the two 9px
/// steps, the exact-time line, the stats row and the verb row. Calibrated against
/// the running app, like the feed's own chrome.
const focal_row_chrome: f32 = focal_leading_pad + avatar_size + 9 + 9 + 20 + 12 + 34 + 35;
/// The reply field's row, which does not change shape with the thread.
const reply_row_extent: f32 = 62;
/// A nested reply's register: a smaller disc, a 13px name, a 13.5 body and 11.5
/// metadata, all one step under the reply it answers.
const nested_avatar_size: f32 = 28;
const nested_name_scale: f32 = 13.0 / 14.5;
const nested_body_scale: f32 = 13.5 / 14.5;
const nested_meta_scale: f32 = 11.5 / 14.5;
const op_chip_scale: f32 = 9.0 / 14.5;
/// A nested reply minus its body, the branch line, and the show-more line, all
/// measured in the running app.
const nested_reply_chrome: f32 = 8 + 20 + 3;
const branch_more_extent: f32 = 6 + 22;
const show_more_extent: f32 = 12 + body_line_height + 10;
const outside_row_extent: f32 = 2 + body_line_height + 12;
/// The chain above the focal note: one compact row per ancestor, each hanging
/// off the rail that runs down to the note being read. The bottom pad IS the
/// rail's segment between two discs, so it is a layout number and an estimate
/// term at once.
pub const ancestor_top_pad: f32 = 14;
const ancestor_bottom_pad: f32 = 14;
const ancestor_identity_gap: f32 = 4;
/// An ancestor's body is clamped to two lines: the SDK has no multi-line clamp
/// (`TextOverflow.ellipsis` is single-line only), so the cut is made in the spans
/// before they are laid out. The column is the estimator's own 70 characters per
/// line at the 14.5 body, held to the 13.5 register.
const ancestor_body_lines: usize = 2;
/// A quote is an aside, so it shows four lines of the note it quotes and stops
/// (11f). Its height is then known where the row around it is priced.
const quote_body_lines: usize = 4;
/// What a quote still resolving reserves, so the row keeps its height when the
/// note lands.
const quote_skeleton_height: f32 = 34;
/// The depth-1 pill's own height, stated because a `list_item` floors at 28.
const quote_pill_height: f32 = 22;
/// How wide the pill's one line may run before it elides, so a quoted note with
/// a lot to say cannot push the pill across the row.
const quote_pill_label_width: f32 = 190;
/// A picture and the chips over it (11o): the corner inset, the chip's own
/// height, and how much of each label may run before it elides. The alt chip is
/// given room for a phrase, the dimensions chip for `4032x3024`.
const picture_radius: f32 = 10;
const picture_chip_inset: f32 = 8;
const picture_chip_height: f32 = 18;
/// The chips' own 10px mono register, a rung below the metadata mono.
const mono_chip_scale: f32 = 10.0 / 14.5;
/// The picture's box: the reading column it spans, the aspect past which a very
/// tall picture is contained rather than taking over the feed, and the shape to
/// assume when the note says nothing and nothing has been decoded yet.
const picture_column_width: f32 = feed_column_width - row_pad_side * 2 - avatar_size - avatar_to_text_gap;
pub const picture_column_width_for_test: f32 = picture_column_width;
const picture_max_aspect: f32 = 1.25;
const picture_default_aspect: f32 = 0.66;
/// The composer sheet (11l): its width, the header band, and how tall the editor
/// stands before it scrolls (about eight lines of its own register).
const compose_sheet_width: f32 = 560;
const compose_header_height: f32 = 38;
const compose_editor_height: f32 = 150;
/// How many bands a striped placeholder may draw. A tall picture would otherwise
/// spend fifty widget nodes on a fill nobody reads, against a 1024-node ceiling
/// that refuses the whole view when it is crossed.
const picture_stripe_cap: usize = 24;
/// The off-state chip's own height.
const picture_ask_height: f32 = 24;
/// A link card, with and without a description. Its TEXT column sets the height,
/// not its 30px tile: the domain, title and description each take a full body
/// line box whatever register they are set in (a span scaled down keeps the line
/// it is given). MEASURED, like every other row constant here, because summing
/// the parts is what got the last three wrong.
const link_card_height: f32 = 77.125;
const link_card_height_bare: f32 = 57;
pub const link_card_height_for_test: f32 = link_card_height;
pub const link_card_height_bare_for_test: f32 = link_card_height_bare;

/// Files a preview as if a page had answered, for a test that renders the card.
pub fn seedLinkForTest(url: []const u8, title: []const u8, desc: []const u8) void {
    const slot = wantLink(url) orelse return;
    storeLinkMeta(slot, .{ .title = title, .description = desc });
    slot.state = .loaded;
}
/// A quote's aside minus its body lines: the 5 above it, the 2 either side, the
/// identity block beside the disc and the gaps between the column's three
/// children. MEASURED in the running layout rather than summed from those parts,
/// the way every other row constant here now is, because summing them was wrong
/// by a line and a half and nothing said so.
const quote_aside_chrome: f32 = 62.125;
/// The same for a quote that has not arrived, or never will: the 5 above it, the
/// column's sibling gap and the 2px pads, and NO identity block, because those
/// states draw a bar or a single line where the identity would be.
const quote_quiet_chrome: f32 = 5 + 4 + 2 + 2;
const ancestor_chars_per_line: usize = @intFromFloat(70 / nested_body_scale);
/// A body line is a BODY line whatever register it is set in: `textSpansMaxScale`
/// starts at 1 and only takes the max, so a paragraph whose spans are all scaled
/// DOWN still gets `14.5 * 1.25`. Scale shrinks glyphs, never the line box, and
/// every term here that priced a scaled run at its own size was short.
const ancestor_line_height: f32 = body_line_height;
const ancestor_row_chrome: f32 = avatar_size + ancestor_identity_gap + ancestor_bottom_pad;
/// A ghost row: its two quiet lines set the height, not the dashed disc. Both are
/// scaled down and both still take a full body line box (see
/// `ancestor_line_height`), which puts the text column past the 36px disc.
const ghost_row_extent: f32 = 2 + body_line_height + 3 + body_line_height + ancestor_bottom_pad;
/// The listening footer, and the focal note's own leading space when it is the
/// first row (an ancestor's bottom pad provides it otherwise).
const listening_row_extent: f32 = 8 + 1 + 10 + body_line_height + 10;
const focal_leading_pad: f32 = 16;
/// One wrapped body line, as the engine actually lays it out (`size * 1.25` at a
/// 14.5 body). Measured live, and the estimator's unit.
pub const body_line_height: f32 = 18.125;
/// The redesign's metadata register: 12px for handles, timestamps and counts.
/// `.size = .sm` cannot say it (the size enum steps by exactly one from the 14.5
/// body, giving 13.5), so these runs are scaled spans, which take an exact
/// multiplier.
pub const meta_size: f32 = 12;
/// A thread reply row minus its body, in the same terms as the feed's. The thread
/// keeps its own 14px inset and a single-line identity beside the disc until PR-5
/// rebuilds those rows to the 11k spec, at which point these are re-measured the
/// way the feed's were.
const thread_row_pad: f32 = 14;
const thread_reply_chrome: f32 = thread_row_pad + avatar_size + 5 + 5 + engagement_row_height + thread_row_pad + 1;
const thread_skeleton_extent: f32 = 76;
const meta_scale: f32 = meta_size / 14.5;
/// The name: 14px, one step under the body, in the medium face. The mock asks for
/// 600 and the bundled family steps 400 / 500 / 700, so medium is the nearer rung.
const name_scale: f32 = 14.0 / 14.5;
/// The engagement strip's measured height: the count's line box, which is taller
/// than the 15px glyphs beside it. It was 28 while the verbs were `.list_item`s,
/// a kind that carries an intrinsic 28px row-height floor; they are plain
/// pressable rows now, so the strip measures what it draws.
pub const engagement_row_height: f32 = 18.125;
/// A feed row minus its body: the insets, the identity block pinned to the disc,
/// the two vertical steps, the verbs, and the hairline. Every term is the
/// redesign's own number, so the estimate cannot drift from the layout.
pub const feed_row_chrome: f32 = row_pad_top + avatar_size + 5 + 10 + engagement_row_height + row_pad_bottom + 1;

pub const max_avatar_images = 10;
const max_media_images = 6;
comptime {
    // The split may never promise more ids than the registry owns: overshooting
    // shows up as a silent `error.ImageRegistryFull` at the 17th registration,
    // which reads as "this author has no avatar" rather than as a budget bug.
    if (max_avatar_images + max_media_images > image_registry_slots) {
        @compileError("the image budget oversubscribes the canvas registry");
    }
}
const media_image_id_base: u64 = max_avatar_images + 1;
// What each image is requested at. Avatars draw at 40pt, so asking for more
// than a couple of hundred pixels is pure waste. Feed images are bounded as a
// BOX, not just a width: the registry's budget is 1 MiB of decoded pixels, so a
// 512-wide image that happens to be tall (512x717 is a real example) still
// blows it. 480x480 leaves honest headroom under the cap.
const avatar_target_px: u32 = 128;
const media_target_px: u32 = 480;
// The largest body we accept from a fetch. The effect caps at 256 KiB anyway;
// stopping a little short keeps the decode budget for images that will fit.
const max_image_bytes = 240 * 1024;
// The registry's own ceiling on one decoded image.
const max_registered_image_bytes = 1024 * 1024;
// Animated GIFs decode every frame up front, so they are bounded twice over: by
// frame count and by total decoded bytes. An animated GIF is asked for at this
// smaller size, since it has to arrive whole inside the fetch cap.
const gif_target_px: u32 = 240;
const max_gif_frames = 64;
const max_gif_total_bytes = 24 * 1024 * 1024;
// How many play at once, and how often the shared animation timer ticks.
const max_playing_gifs = 2;
const animation_interval_ms: u32 = 80;
const animation_timer_key: u64 = 2;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view, native_sdk.security.permission_clipboard, native_sdk.security.permission_network };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Plaza canvas", .accessibility_label = "Plaza", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Plaza",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------- one-process runtime wiring
//
// A native app is a single process and a single instance, so the shared store,
// each relay's connection state, and the wall clock live as process globals,
// the Model stays pure view state (the framework reflects Model/Msg for markup
// checking). Sharing the store across the UI thread and the several ingest
// threads is safe: LMDB serialises its writers (the pool's ingests take the
// write lock one at a time) and hands readers an MVCC snapshot, and every
// `nostr.store` call is a self-contained transaction on its calling thread.

const Conn = enum(u8) { connecting = 0, connected = 1, offline = 2 };

var g_store: ?*nostr.store.Store = null;
// One connection state per relay in the pool, flipped by that relay's ingest
// thread and read by the UI thread to summarise the pool.
var g_relay_status = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(@intFromEnum(Conn.connecting))} ** relays.len;

/// Arrival order inside a thread level: the build a reply first appeared in, so a
/// late arrival lands after what has already been read instead of jumping into the
/// middle of it. The redesign is explicit about this ("appended, never reordered"),
/// and a reply that arrives late is often OLDER than replies already on screen, so
/// created_at alone would move the ground under the reader.
///
/// One table PER LEVEL, keyed by that level's root: a thread stays mounted while
/// the reader walks into a sub-thread and back, and it has to come back in the
/// order they left it. A single shared table meant opening any reply reshuffled
/// the conversation underneath it.
const ArrivalTable = struct {
    const Entry = struct {
        used: bool = false,
        id: [32]u8 = [_]u8{0} ** 32,
        batch: u32 = 0,
    };
    /// The level's root, so a table found holding a different thread is discarded
    /// rather than trusted.
    root: [32]u8 = [_]u8{0} ** 32,
    entries: [thread_reply_cap]Entry = [_]Entry{.{}} ** thread_reply_cap,
    batch: u32 = 0,
    /// Whether this level's own fetch has settled. Everything collected before it
    /// does is ONE batch, in written order, however the relays interleave it;
    /// only what shows up afterwards is genuinely late.
    settled: bool = false,
};
/// One per mounted level: the back-stack plus the open thread.
var g_arrival: [thread_depth_max + 1]ArrivalTable = [_]ArrivalTable{.{}} ** (thread_depth_max + 1);

/// A fresh arrival table, for a test that drives the real stamping.
pub fn arrivalTableForTest() ArrivalTable {
    return .{};
}

pub fn stampArrivalForTest(table: *ArrivalTable, notes: []Note, settled: bool) void {
    stampArrival(table, notes, settled);
}

/// The arrival table for `level`, reset if it is holding a different thread.
fn arrivalTableFor(level: usize, root: [32]u8) *ArrivalTable {
    const table = &g_arrival[@min(level, g_arrival.len - 1)];
    if (!std.mem.eql(u8, &table.root, &root)) table.* = .{ .root = root };
    return table;
}

/// Stamps each note with the batch it first appeared in and puts the level in
/// reading order. One pass over the notes: an id the level has not shown before
/// opens the next batch (unless the level is still loading, when everything
/// belongs to the first), and every id after it in the same build joins it.
///
/// `settled` is whether this level's own fetch has finished. Until it has, the
/// relays are still streaming the thread's opening state, and treating each
/// 80ms slice of that stream as a batch would pin the conversation into
/// relay-answer order, which is precisely what this exists to prevent.
fn stampArrival(table: *ArrivalTable, notes: []Note, settled: bool) void {
    var opened = false;
    for (notes) |*note| {
        if (arrivalOf(table, note.event_id)) |batch| {
            note.arrival = batch;
            continue;
        }
        if (!opened) {
            if (table.settled) table.batch += 1;
            opened = true;
        }
        note.arrival = claimArrival(table, note.event_id, notes);
    }
    if (settled) table.settled = true;
    sortThreadNotes(notes);
}

/// The batch `id` was first seen in, or null when this level has not shown it.
fn arrivalOf(table: *const ArrivalTable, id: [32]u8) ?u32 {
    for (&table.entries) |*e| {
        if (e.used and std.mem.eql(u8, &e.id, &id)) return e.batch;
    }
    return null;
}

/// Records `id` at the current batch. The table holds exactly as many entries as
/// a level can show, so a full table means it is holding ids that have since left
/// the set (the fetch cap re-cuts as the store grows): those are swept, and the
/// claim retried. Failing that the id takes the current batch unrecorded, which
/// still reads in order for this build.
fn claimArrival(table: *ArrivalTable, id: [32]u8, live: []const Note) u32 {
    for (&table.entries) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .id = id, .batch = table.batch };
            return e.batch;
        }
    }
    for (&table.entries) |*e| {
        var still_here = false;
        for (live) |*note| {
            if (std.mem.eql(u8, &note.event_id, &e.id)) {
                still_here = true;
                break;
            }
        }
        if (!still_here) e.* = .{};
    }
    for (&table.entries) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .id = id, .batch = table.batch };
            return e.batch;
        }
    }
    return table.batch;
}

/// A thread level's reading order: the batch a reply arrived in, then when it was
/// written. ONE comparator, called by the open thread and by every level under
/// it, so a level reads the same both ways round.
pub fn sortThreadNotes(notes: []Note) void {
    std.mem.sort(Note, notes, {}, struct {
        fn lt(_: void, a: Note, b: Note) bool {
            // Arrival first, then chronological within a batch: a reply that
            // showed up later sits after the ones already read, even when it was
            // written earlier.
            if (a.arrival != b.arrival) return a.arrival < b.arrival;
            return a.created_at < b.created_at;
        }
    }.lt);
}

/// Sets relay `index`'s live connection state.
fn setRelayStatus(index: usize, state: Conn) void {
    g_relay_status[index].store(@intFromEnum(state), .monotonic);
}

/// Whether the reader has paused the pool. Read by every relay thread between
/// reconnect attempts, so a pause takes hold without tearing a socket down
/// mid-message.
var g_relays_paused = std.atomic.Value(bool).init(false);

fn setRelaysPaused(paused: bool) void {
    g_relays_paused.store(paused, .monotonic);
}

pub fn relaysPaused() bool {
    return g_relays_paused.load(.monotonic);
}

/// A relay's round-trip time in milliseconds, sampled REQ to EOSE and kept as a
/// small ring so the bar can show a median rather than the last spike. Zero means
/// no sample yet.
const rtt_samples = 8;
/// The latency probe: a one-event query whose round trip is the number the status
/// bar shows, and how often each relay is asked for it.
const probe_sub = "plaza-ping";
const probe_interval_ms: i64 = 20_000;
var g_relay_rtt = [_][rtt_samples]std.atomic.Value(u16){[_]std.atomic.Value(u16){std.atomic.Value(u16).init(0)} ** rtt_samples} ** relays.len;
var g_relay_rtt_at = [_]std.atomic.Value(u8){std.atomic.Value(u8).init(0)} ** relays.len;

/// Records one round trip for relay `index`. Stored as milliseconds PLUS ONE, so
/// a sub-millisecond answer (a warm or local relay, truncated to 0) is a reading
/// rather than an empty slot.
pub fn recordRelayRttForTest(index: usize, ms: u64) void {
    recordRelayRtt(index, ms);
}

pub fn clearRelayRttForTest(index: usize) void {
    clearRelayRtt(index);
}

fn recordRelayRtt(index: usize, ms: u64) void {
    if (index >= relays.len) return;
    const slot = g_relay_rtt_at[index].load(.monotonic) % rtt_samples;
    g_relay_rtt[index][slot].store(@intCast(@min(ms, std.math.maxInt(u16) - 1) + 1), .monotonic);
    g_relay_rtt_at[index].store(slot +% 1, .monotonic);
}

/// Forgets relay `index`'s samples. Called when it drops, so the bar never shows
/// a number measured on a connection that no longer exists.
fn clearRelayRtt(index: usize) void {
    if (index >= relays.len) return;
    for (&g_relay_rtt[index]) |*sample| sample.store(0, .monotonic);
}

/// Relay `index`'s median round trip, or null when it has never answered.
pub fn relayRttMs(index: usize) ?u16 {
    if (index >= relays.len) return null;
    var seen: [rtt_samples]u16 = undefined;
    var n: usize = 0;
    for (&g_relay_rtt[index]) |*sample| {
        const v = sample.load(.monotonic);
        if (v != 0) {
            seen[n] = v - 1;
            n += 1;
        }
    }
    if (n == 0) return null;
    std.mem.sort(u16, seen[0..n], {}, std.sort.asc(u16));
    return median(seen[0..n]);
}

/// The middle of a sorted run, averaging the two middles for an even count so a
/// four-sample reading is not silently the third-fastest.
fn median(sorted: []const u16) u16 {
    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[mid];
    return @intCast((@as(u32, sorted[mid - 1]) + @as(u32, sorted[mid])) / 2);
}

/// The pool's latency: the median across every relay that has answered. The
/// redesign asks for the median WRITE relay, the number that predicts how fast a
/// post lands; until a relay list with read/write markers exists, every relay in
/// the pool is both, so this is that number.
pub fn poolLatencyMs() ?u16 {
    var seen: [relays.len]u16 = undefined;
    var n: usize = 0;
    for (0..relays.len) |i| {
        // Connected relays only: a number measured before a relay dropped says
        // nothing about how fast the pool answers now.
        const state: Conn = @enumFromInt(g_relay_status[i].load(.monotonic));
        if (state != .connected) continue;
        if (relayRttMs(i)) |ms| {
            seen[n] = ms;
            n += 1;
        }
    }
    if (n == 0) return null;
    std.mem.sort(u16, seen[0..n], {}, std.sort.asc(u16));
    return median(seen[0..n]);
}
// The UI thread's Io, for wall-clock time when rendering relative timestamps
// (set once in `main`, read only on the UI thread).
var g_io: ?std.Io = null;
// The process environment, stashed in `main` so the onboarding "create identity"
// action can resolve `$HOME` and open the store off the UI thread event loop.
var g_environ: ?*const std.process.Environ.Map = null;
// The event count at the last feed rebuild, a cheap "did the store change?"
// signal so a tick that changed nothing skips the query and note rebuild.
var g_last_count: usize = std.math.maxInt(usize);

// Plaza's local identity: the keypair that signs composed notes. Loaded in
// `main` (returning user) or created by the onboarding action, both on the UI
// thread, and read only there, so no synchronisation is needed. The signer holds
// a secp256k1 context (not shared across threads); the publish path never signs,
// it forwards an already-signed event, so it needs neither. This is the
// zero-config local signer; connecting an external signer (Signet, over NIP-46,
// so the key never touches the client) is the next onboarding option, and swaps
// in at `signAndPublish` below.
var g_identity_signer: ?nostr.keys.Signer = null;
var g_identity_kp: ?nostr.keys.KeyPair = null;
var g_identity_npub_buf: [24]u8 = undefined;
var g_identity_npub_len: usize = 0;

// How composed notes are signed: with the local key, or remotely over NIP-46 by
// an external signer (Signet) so the secret key never enters Plaza. `submitPost`
// branches on this; it is set once during onboarding.
const SignerKind = enum { local, remote, helper };
var g_signer_kind: SignerKind = .local;

// Remote-signer (NIP-46) connection state, set at connect time and read by the
// background threads. The ephemeral client keypair is Plaza's transport identity
// with the bunker (never the user's key); the user's identity is the bunker's
// own pubkey. Each worker thread makes its own secp256k1 signer, only these
// bytes are shared.
var g_remote_client_kp: ?nostr.keys.KeyPair = null;
var g_remote_pubkey: [32]u8 = undefined;
var g_remote_relay_buf: [256]u8 = undefined;
var g_remote_relay_len: usize = 0;
var g_remote_secret_buf: [128]u8 = undefined;
var g_remote_secret_len: usize = 0;
// 0 idle, 1 connecting, 2 connected, 3 failed. Drives the onboarding status line.
var g_remote_status = std.atomic.Value(u8).init(0);
// Monotonic source of unique NIP-46 request ids.
var g_req_counter = std.atomic.Value(u64).init(0);

// ------------------------------------------------- the isolated signer helper
//
// plaza-signer holds the key in a separate PROCESS, reached over loopback HTTP.
// Plaza spawns it at launch, writes it a 0600 bearer token, and (for now)
// health-checks it; routing the actual signing through it comes next. The port
// is Plaza-specific (not signet's 8787), so a standalone Signet and the
// built-in one never collide.
const helper_port: u16 = 8790;
const helper_spawn_key: u64 = 40;
const helper_poll_key: u64 = 41;
// The daemon binary (a sibling of Plaza's own executable) and the shared token,
// resolved once in main and read by boot/tick.
var g_helper_bin_buf: [1024]u8 = undefined;
var g_helper_bin_len: usize = 0;
var g_helper_token_buf: [64]u8 = undefined;
var g_helper_token_len: usize = 0;
var g_helper_state_dir_buf: [512]u8 = undefined;
var g_helper_state_dir_len: usize = 0;
var g_helper_token_path_buf: [512]u8 = undefined;
var g_helper_token_path_len: usize = 0;
// 0 starting, 1 uninitialized (reachable, no key yet), 2 ready (holds a key),
// 3 unreachable. Reachable at all (1 or 2) is what proves the loopback IPC.
var g_helper_state = std.atomic.Value(u8).init(0);
/// When the signed-in health check last ran, and how often it may run. The
/// signed-out poll is every tick (it is waiting for a key to appear); this is the
/// quieter beat that keeps the status bar honest afterwards.
var g_helper_polled_at: i64 = 0;
const helper_health_interval_s: i64 = 5;

fn helperBin() []const u8 {
    return g_helper_bin_buf[0..g_helper_bin_len];
}
fn helperToken() []const u8 {
    return g_helper_token_buf[0..g_helper_token_len];
}

/// Resolves the daemon path (a sibling of argv[0], so it works both from the
/// dev tree and a packaged bundle), mints a fresh bearer token, and writes it
/// 0600 under ~/.plaza. Best-effort: on any failure the helper simply never
/// comes up and signing keeps to its current in-process path.
fn resolveHelper(init: std.process.Init) void {
    // The daemon lives beside Plaza's own executable.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    const argv0 = args.next() orelse return;
    const dir = std.fs.path.dirname(argv0) orelse ".";
    const bin = std.fmt.bufPrint(&g_helper_bin_buf, "{s}/plaza-signer", .{dir}) catch return;
    g_helper_bin_len = bin.len;

    const home = init.environ_map.get("HOME") orelse ".";
    const state_dir = std.fmt.bufPrint(&g_helper_state_dir_buf, "{s}/.plaza", .{home}) catch return;
    g_helper_state_dir_len = state_dir.len;
    const token_path = std.fmt.bufPrint(&g_helper_token_path_buf, "{s}/.plaza/signer.token", .{home}) catch return;
    g_helper_token_path_len = token_path.len;

    // A fresh 32-byte token, hex-encoded, so a stray process on the machine
    // cannot drive the signer even if it guesses the port.
    var raw: [32]u8 = undefined;
    init.io.randomSecure(&raw) catch return;
    var hexbuf: [64]u8 = undefined;
    _ = hexLower(&hexbuf, raw);
    @memcpy(g_helper_token_buf[0..64], &hexbuf);
    g_helper_token_len = 64;

    var d = plazaDir(init.io, init.environ_map) catch return;
    defer d.close(init.io);
    d.writeFile(init.io, .{
        .sub_path = "signer.token",
        .data = &hexbuf,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch return;
}

// The Signet ceremony window binary. In a packaged app it sits beside Plaza in
// Contents/MacOS; in the dev tree it is the sub-project's own build output.
var g_signet_win_buf: [1024]u8 = undefined;
var g_signet_win_len: usize = 0;
const signet_spawn_key: u64 = 44;
const helper_reset_key: u64 = 45;
// Set on logout, so the health-check does not re-adopt the daemon's key before
// the async /reset lands. Cleared when the user explicitly signs in again.
var g_logged_out: bool = false;

fn resolveSignetWindow(init: std.process.Init) void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    const argv0 = args.next() orelse return;
    const dir = std.fs.path.dirname(argv0) orelse ".";
    // Packaged: a sibling. Dev: the sub-project's zig-out. Take whichever is
    // there, sibling first (that is the shipped layout).
    const sibling = std.fmt.bufPrint(&g_signet_win_buf, "{s}/signet-window", .{dir}) catch return;
    if (std.Io.Dir.cwd().access(init.io, sibling, .{})) |_| {
        g_signet_win_len = sibling.len;
        return;
    } else |_| {}
    const dev = std.fmt.bufPrint(&g_signet_win_buf, "{s}/../../signet-window/zig-out/bin/signet-window", .{dir}) catch return;
    if (std.Io.Dir.cwd().access(init.io, dev, .{})) |_| {
        g_signet_win_len = dev.len;
    } else |_| g_signet_win_len = 0;
}

/// Opens the Signet ceremony window (a separate process) for a key import, so
/// the pasted key never enters Plaza. The window reads the token itself and
/// talks to the daemon; Plaza adopts the identity when the key appears
/// (see handleHelperPubkey). No args needed.
fn spawnSignetWindow(fx: *Effects) void {
    if (g_signet_win_len == 0) return;
    fx.spawn(.{
        .key = signet_spawn_key,
        .argv = &.{g_signet_win_buf[0..g_signet_win_len]},
        .output = .collect,
    });
}

/// Tells the daemon to forget the key (wipe memory + delete the file), so a
/// logout is not undone when the health-check next reads /pubkey. Fire and
/// forget; the g_logged_out latch covers the window until it lands.
fn helperReset(fx: *Effects) void {
    if (g_helper_token_len == 0) return;
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/reset", .{helper_port}) catch return;
    var auth_buf: [96]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{helperToken()}) catch return;
    fx.fetch(.{
        .key = helper_reset_key,
        .url = url,
        .method = .POST,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
    });
}

/// Spawns the keyholder daemon: keyless, it idles serving /pubkey and /setup.
/// The parent-pid is Plaza's, so the daemon exits when Plaza does.
fn spawnHelper(fx: *Effects) void {
    if (g_helper_bin_len == 0 or g_helper_token_len == 0) return;
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{helper_port}) catch return;
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch return;
    fx.spawn(.{
        .key = helper_spawn_key,
        .argv = &.{
            helperBin(),    "--serve",
            "--port",       port_str,
            "--state-dir",  g_helper_state_dir_buf[0..g_helper_state_dir_len],
            "--token-file", g_helper_token_path_buf[0..g_helper_token_path_len],
            "--parent-pid", pid_str,
        },
        .on_exit = Effects.exitMsg(.helper_exited),
        .output = .collect,
    });
}

/// Health-checks the daemon: GET /pubkey with the bearer token. A 200 (in any
/// state) proves the loopback IPC works; a connection error keeps it at
/// unreachable and the tick tries again.
fn pollHelper(fx: *Effects) void {
    if (g_helper_token_len == 0) return;
    // Signed OUT, this proves the IPC at startup and catches a key appearing
    // later (a terminal or window import), so Plaza adopts it live: poll every
    // tick. Signed IN, the status bar now reports whether Signet can actually
    // sign, and a stale flag there would be a chip that lies, so keep polling,
    // slowly. Only for a Signet identity: a local key or a bunker has nothing on
    // the other end of this socket.
    if (activePubkey() != null) {
        if (g_signer_kind != .helper) return;
        const now = nowSeconds();
        if (now - g_helper_polled_at < helper_health_interval_s) return;
        g_helper_polled_at = now;
    }
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/pubkey", .{helper_port}) catch return;
    var auth_buf: [96]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{helperToken()}) catch return;
    fx.fetch(.{
        .key = helper_poll_key,
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .on_response = Effects.responseMsg(.helper_pubkey),
    });
}

/// Records the health-check result. A reachable daemon (200) tells us the IPC
/// works; the body says whether it already holds a key.
fn handleHelperPubkey(model: *Model, response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok or response.status != 200) {
        g_helper_state.store(3, .release); // unreachable, keep retrying
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body) catch return;
    defer parsed.deinit();
    const ready = std.mem.eql(u8, parsed.value.state, nostr.signer_ipc.state_ready);
    g_helper_state.store(if (ready) 2 else 1, .release);
    if (!ready) return;

    // The daemon holds a key and Plaza is a guest: adopt it. This is how a
    // terminal or window import (which Plaza did not initiate) signs the user
    // in live. A Plaza-initiated setup is left to handleHelperSetup, which owns
    // the name beat and the remembered intent.
    if (g_logged_out) return; // a just-logged-out session must stay out
    if (activePubkey() != null) return;
    if (g_helper_setup != .none or g_helper_pending_in_flight != .none) return;
    if (!restoreHelperIdentity(parsed.value.pubkey)) return;
    persistSession();
    enterFeed(model);
    replayPending(model);
}

// The signed-in helper identity: its pubkey lives here (the SECRET lives only in
// the daemon). `.helper` is the built-in local key now; `g_identity_kp` stays
// null for it, so the key is never in this process.
var g_helper_identity_pk: [32]u8 = undefined;
var g_helper_has_identity = false;

// Helper setup is async and can race the daemon coming up, so an intent is
// queued and fired by the tick once the daemon is reachable. `create` mints a
// fresh key (then the name beat); `import_user` adopts a pasted nsec; `migrate`
// moves a legacy in-process key into the daemon and deletes it, silently.
const HelperSetup = enum { none, create, import_user, migrate };
var g_helper_setup: HelperSetup = .none;
var g_helper_setup_secret: [32]u8 = undefined;
const helper_setup_key: u64 = 42;
const helper_sign_key: u64 = 43;

fn helperReachable() bool {
    return g_helper_state.load(.acquire) >= 1;
}

/// Queues a helper setup and fires it now if the daemon is already up (else the
/// tick fires it the moment the health-check confirms reachability).
fn queueHelperSetup(fx: *Effects, kind: HelperSetup, secret: ?[32]u8) void {
    g_logged_out = false; // an explicit sign-in re-enables adopt-on-appear
    g_helper_setup = kind;
    if (secret) |sk| g_helper_setup_secret = sk;
    driveHelperSetup(fx);
}

/// Fires a queued setup once the daemon is reachable. Called on the tick and
/// right after queueing.
fn driveHelperSetup(fx: *Effects) void {
    if (g_helper_setup == .none or !helperReachable()) return;
    const gpa = std.heap.page_allocator;
    switch (g_helper_setup) {
        .none => {},
        .create => helperFetch(fx, helper_setup_key, "/setup", "{\"method\":\"create\"}", Effects.responseMsg(.helper_setup)),
        .import_user, .migrate => {
            const nsec = nostr.nip19.encodeNsec(gpa, g_helper_setup_secret) catch return;
            defer gpa.free(nsec);
            std.crypto.secureZero(u8, &g_helper_setup_secret);
            var body_buf: [128]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"method\":\"import\",\"secret\":\"{s}\"}}", .{nsec}) catch return;
            defer std.crypto.secureZero(u8, &body_buf);
            helperFetch(fx, helper_setup_key, "/setup", body, Effects.responseMsg(.helper_setup));
        },
    }
    // In flight now; the response either completes it or, on failure, requeues.
    g_helper_pending_in_flight = g_helper_setup;
    g_helper_setup = .none;
}
var g_helper_pending_in_flight: HelperSetup = .none;

/// A POST to the daemon with the bearer token. The body is copied by the effect,
/// so a stack buffer is fine.
fn helperFetch(fx: *Effects, key: u64, comptime path: []const u8, body: []const u8, on_response: @TypeOf(Effects.responseMsg(.helper_setup))) void {
    var url_buf: [48]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}" ++ path, .{helper_port}) catch return;
    var auth_buf: [96]u8 = undefined;
    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{helperToken()}) catch return;
    fx.fetch(.{
        .key = key,
        .url = url,
        .method = .POST,
        .headers = &.{.{ .name = "Authorization", .value = auth }},
        .body = body,
        .on_response = on_response,
    });
}

/// Sends one event of `kind` (with `tags`, stamped `created`) to the daemon to
/// be signed. Builds the unsigned event against the helper's own pubkey so the
/// returned id matches, wraps it, and POSTs /sign; the response is the signed
/// event, ingested and published like any other. `content_owned` and `tags` are
/// process-lifetime (the local and remote paths reference them too), so this
/// does not free them.
fn requestHelperSign(fx: *Effects, gpa: std.mem.Allocator, created: i64, kind: u16, tags: []const nostr.event.Tag, content_owned: []const u8) void {
    const pk = activePubkey() orelse return;
    const id = nostr.event.computeId(gpa, pk, created, kind, tags, content_owned) catch return;
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = pk,
        .created_at = created,
        .kind = kind,
        .tags = tags,
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch return;
    defer gpa.free(unsigned_json);
    const body = (nostr.signer_ipc.SignEvent{ .event = unsigned_json }).toJson(gpa) catch return;
    defer gpa.free(body);
    helperFetch(fx, helper_sign_key, "/sign", body, Effects.responseMsg(.helper_signed));
}

/// Adopts a helper-held identity: only the pubkey lives here, never the secret
/// (that stays in the daemon). Clears any in-UI local key.
fn adoptHelperIdentity(pk: [32]u8) void {
    if (g_identity_signer) |*sig| sig.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_helper_identity_pk = pk;
    g_helper_has_identity = true;
    g_signer_kind = .helper;
    const npub = abbreviateNpub(&g_identity_npub_buf, pk);
    g_identity_npub_len = npub.len;
    g_last_count = std.math.maxInt(usize);
}

/// Restores a helper identity from a persisted session pubkey. Synchronous: the
/// daemon independently loads its own key, so Plaza only needs to know who it is.
fn restoreHelperIdentity(pubkey_hex: []const u8) bool {
    if (pubkey_hex.len != 64) return false;
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pubkey_hex) catch return false;
    adoptHelperIdentity(pk);
    return true;
}

/// Completes an async helper setup. On a fresh create it adopts the minted
/// identity and opens the name beat; a transient failure requeues for the tick.
fn handleHelperSetup(model: *Model, response: native_sdk.EffectResponse) void {
    const purpose = g_helper_pending_in_flight;
    g_helper_pending_in_flight = .none;
    if (response.outcome != .ok) {
        g_helper_setup = purpose; // the daemon was not up; the tick retries
        return;
    }
    if (response.status != 200) {
        // A migration is a silent background upgrade: on failure the in-process
        // key keeps working, so say nothing. Foreground setups report.
        if (purpose != .migrate) setToast(model, "Could not set up your key");
        return;
    }
    const gpa = std.heap.page_allocator;
    var parsed = nostr.signer_ipc.parse(nostr.signer_ipc.Pubkey, gpa, response.body) catch return;
    defer parsed.deinit();
    if (!restoreHelperIdentity(parsed.value.pubkey)) return;
    persistSession();
    switch (purpose) {
        .create => {
            enterFeed(model);
            model.naming = true; // the name beat; replay follows it
        },
        .import_user => {
            enterFeed(model);
            replayPending(model);
        },
        // A completed migration: the daemon now holds the key, so delete the
        // in-process file. The user was already signed in; nothing else changes.
        .migrate => deleteIdentityKeyFile(),
        .none => {},
    }
}

/// Deletes the legacy in-process key file, once its secret is safe in the daemon.
fn deleteIdentityKeyFile() void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    dir.deleteFile(io, "identity.key") catch {};
}

/// Ingests and publishes a signed event returned by the daemon. Trusted: it
/// came from our own daemon over authenticated loopback. A kind:0 seeds the
/// profile cache so the name shows at once.
fn handleHelperSigned(response: native_sdk.EffectResponse) void {
    if (response.outcome != .ok or response.status != 200) return;
    const gpa = std.heap.page_allocator;
    var wrapped = nostr.signer_ipc.parse(nostr.signer_ipc.SignEvent, gpa, response.body) catch return;
    defer wrapped.deinit();
    var parsed = nostr.event.fromJson(gpa, wrapped.value.event) catch return;
    defer parsed.deinit();
    const owned = gpa.dupe(u8, parsed.value.content) catch return;
    var out = parsed.value;
    out.content = owned;
    // Preserve the signed event's tags (a reaction carries e/p/k): forcing them
    // empty would leave the published id not matching its content, so relays
    // would reject it. Deep-copied because `parsed` is freed on return.
    out.tags = dupeTags(gpa, parsed.value.tags);
    if (out.kind == 0) {
        if (upsertProfile(out.pubkey)) |prof| parseMetadataInto(prof, owned);
    }
    ingestAndPublish(gpa, out, null);
}
// The listener runs for one connection generation. A logout or a reconnect
// bumps this; the detached listener and the in-flight workers see the change
// and stop, so an old bunker's listener never processes into a new session (or
// a dead one). Correlating this into every pending request is the teardown fix.
var g_remote_generation = std.atomic.Value(u64).init(0);
// A remote sign that never came back, surfaced once in the composer identity
// line so a restored draft is explained rather than silently reappearing.
// Set by the timeout scan, cleared on the next edit or a later success.
var g_remote_sign_notice = std.atomic.Value(bool).init(false);

// Pending NIP-46 requests, keyed by id, so a response is correlated to the
// request that asked for it (not guessed from whether `result` parses as an
// event), and a request that never returns times out instead of losing the
// draft. A tiny spinlock guards the table: every critical section is a handful
// of field writes or an 8-slot scan and never touches IO, so a lock this cheap
// is the right tool (std.Io.Mutex would drag a per-thread `io` through every
// access, across threads that deliberately never share one).
const remote_sign_timeout_s: i64 = 30;
const max_pending_remote = 8;
const RemoteMethod = enum { connect, sign_event };
const PendingRemote = struct {
    active: bool = false,
    id_buf: [24]u8 = undefined,
    id_len: usize = 0,
    method: RemoteMethod = .connect,
    deadline_s: i64 = 0,
    generation: u64 = 0,
    // The listener flags a failed response here; the UI tick, which owns the
    // composer, is what actually restores the draft (see `scanPendingRemote`).
    failed: bool = false,
    // sign_event only: the draft text, restored to the composer on failure or
    // timeout. Owned by the slot; freed when the request resolves or is swept.
    content: ?[]const u8 = null,
    // Whether `content` is a composer draft worth restoring on failure. A
    // reaction (kind:7 "+") is not, so its failure is silent, not a stray "+".
    restorable: bool = false,

    fn id(self: *const PendingRemote) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};
var g_pending_lock = std.atomic.Value(bool).init(false);
var g_pending: [max_pending_remote]PendingRemote = [_]PendingRemote{.{}} ** max_pending_remote;

fn pendingLock() void {
    while (g_pending_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn pendingUnlock() void {
    g_pending_lock.store(false, .release);
}

/// Records a request as awaiting its response, taking ownership of `content`
/// (the draft, for `sign_event`, so a timeout can restore it when `restorable`).
/// Returns false when the table is full or the id does not fit, in which case
/// the caller still owns `content`.
fn registerPending(req_id: []const u8, method: RemoteMethod, content: ?[]const u8, restorable: bool) bool {
    if (req_id.len > 24) return false;
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active) continue;
        slot.* = .{
            .active = true,
            .method = method,
            .id_len = req_id.len,
            .deadline_s = nowSeconds() + remote_sign_timeout_s,
            .generation = g_remote_generation.load(.acquire),
            .content = content,
            .restorable = restorable,
        };
        @memcpy(slot.id_buf[0..req_id.len], req_id);
        return true;
    }
    return false;
}

/// Takes the pending request matching `req_id` out of the table, or null when
/// none matches (an unknown id, or one already resolved: dropping it keeps a
/// duplicated response from publishing twice). The caller owns the returned
/// slot's `content`.
fn takePending(req_id: []const u8) ?PendingRemote {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and std.mem.eql(u8, slot.id(), req_id)) {
            const taken = slot.*;
            slot.* = .{};
            return taken;
        }
    }
    return null;
}

/// Marks the pending request matching `req_id` failed, leaving it in the table
/// for the UI tick to restore the draft and free the content. Returns whether a
/// slot matched.
fn failPending(req_id: []const u8) bool {
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (slot.active and std.mem.eql(u8, slot.id(), req_id)) {
            slot.failed = true;
            return true;
        }
    }
    return false;
}

// Test seams for the NIP-46 pending-request table (the correlation and teardown
// logic), exercised without threads or a live bunker.
pub const RemoteMethodForTest = RemoteMethod;
pub fn registerPendingForTest(req_id: []const u8, method: RemoteMethod, content: ?[]const u8) bool {
    return registerPending(req_id, method, content, content != null);
}
pub fn takePendingContentForTest(req_id: []const u8) ?struct { method: RemoteMethod, content: ?[]const u8 } {
    const taken = takePending(req_id) orelse return null;
    return .{ .method = taken.method, .content = taken.content };
}
pub fn failPendingForTest(req_id: []const u8) bool {
    return failPending(req_id);
}
pub fn clearPendingForTest() void {
    clearPending();
}
pub fn bumpRemoteGenerationForTest() void {
    _ = g_remote_generation.fetchAdd(1, .monotonic);
}
pub fn scanPendingRemoteForTest(model: *Model) void {
    scanPendingRemote(model);
}
pub fn remoteSignNoticeForTest() bool {
    return g_remote_sign_notice.load(.acquire);
}

/// Empties the pending table, freeing every held draft. For logout, so a new
/// session never inherits the old one's in-flight requests.
fn clearPending() void {
    const gpa = std.heap.page_allocator;
    pendingLock();
    defer pendingUnlock();
    for (&g_pending) |*slot| {
        if (!slot.active) continue;
        if (slot.content) |c| gpa.free(c);
        slot.* = .{};
    }
}

// A synchronous error from the unified login field (nsec / bunker), shown under
// it. `.none` while idle or when the async bunker path is in charge (its state
// comes from `g_remote_status`). See `LoginError` and `Model.login_status`.
const LoginError = enum(u8) { none = 0, format = 1, bad_key = 2 };
var g_login_error = std.atomic.Value(u8).init(0);

/// What the pasted login text is: a secret key to import, a signer to connect,
/// or neither.
pub const LoginTarget = enum { nsec, bunker, invalid };

/// Classifies pasted login text by its prefix. Pure, so it is unit-tested.
pub fn classifyLogin(text: []const u8) LoginTarget {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "nsec1")) return .nsec;
    if (std.mem.startsWith(u8, t, "bunker://")) return .bunker;
    return .invalid;
}

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
var g_media_previews: bool = true;

pub fn mediaPreviews() bool {
    return g_media_previews;
}

pub fn setMediaPreviews(on: bool) void {
    g_media_previews = on;
}
var g_media_proxy_buf: [200]u8 = undefined;
var g_media_proxy_len: usize = 0;

/// The configured proxy base URL, empty when images load directly.
pub fn mediaProxy() []const u8 {
    return g_media_proxy_buf[0..g_media_proxy_len];
}

/// Sets the proxy base URL (trimmed; empty disables proxying).
pub fn setMediaProxy(url: []const u8) void {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const n = @min(trimmed.len, g_media_proxy_buf.len);
    @memcpy(g_media_proxy_buf[0..n], trimmed[0..n]);
    g_media_proxy_len = n;
}

/// Whether the host serves its own resized variants via `?w=`, letting us skip
/// the proxy hop entirely. nostr.build's Blossom hosts do; most others ignore it.
fn hostSupportsWidthParam(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "://blossom.nostr.build/") != null or
        std.mem.indexOf(u8, src, "://blossom.band/") != null or
        std.mem.indexOf(u8, src, ".blossom.band/") != null;
}

/// How an image is fitted when resized.
pub const MediaFit = enum {
    /// Square, cropped to fill: avatars.
    square,
    /// Scaled down to fit inside a square box, aspect preserved: feed images.
    /// Bounding both edges is what keeps a tall image inside the pixel budget.
    inside,
    /// Like `inside`, but every frame is kept and the result stays a GIF, so it
    /// can still animate. Asked for smaller, since the whole animation has to
    /// arrive inside the fetch cap.
    animation,
};

/// Whether `src` points at a GIF, which is fetched keeping its frames.
pub fn isGifUrl(src: []const u8) bool {
    const path_end = std.mem.indexOfScalar(u8, src, '?') orelse src.len;
    return std.ascii.endsWithIgnoreCase(src[0..path_end], ".gif");
}

/// Builds the URL to fetch `src` at roughly `width` pixels, writing into `out`
/// and returning the slice to request. Falls back to `src` itself whenever no
/// resizing route applies or the URL would not fit.
pub fn mediaUrl(out: []u8, src: []const u8, width: u32, fit: MediaFit) []const u8 {
    // A host that resizes for us: cheapest path, no third party involved.
    if (hostSupportsWidthParam(src) and std.mem.indexOfScalar(u8, src, '?') == null) {
        return std.fmt.bufPrint(out, "{s}?w={d}", .{ src, width }) catch src;
    }
    const proxy = mediaProxy();
    if (proxy.len == 0) return src;

    var encoded_buf: [768]u8 = undefined;
    const encoded = percentEncode(&encoded_buf, src) orelse return src;
    const sep: []const u8 = if (std.mem.endsWith(u8, proxy, "/")) "" else "/";
    return switch (fit) {
        .square => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=cover&output=webp", .{ proxy, sep, encoded, width, width }) catch src,
        .inside => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=inside&output=webp", .{ proxy, sep, encoded, width, width }) catch src,
        // `n=-1` keeps every frame; the output stays a GIF because that is the
        // animated format the vendored decoder can read frame by frame.
        .animation => std.fmt.bufPrint(out, "{s}{s}?url={s}&w={d}&h={d}&fit=inside&n=-1&output=gif", .{ proxy, sep, encoded, width, width }) catch src,
    };
}

/// Percent-encodes `src` into `out` (everything outside the unreserved set), so
/// a source URL survives as one query parameter. Null if it would not fit.
fn percentEncode(out: []u8, src: []const u8) ?[]const u8 {
    const hexdigits = "0123456789ABCDEF";
    var n: usize = 0;
    for (src) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            if (n + 1 > out.len) return null;
            out[n] = c;
            n += 1;
        } else {
            if (n + 3 > out.len) return null;
            out[n] = '%';
            out[n + 1] = hexdigits[c >> 4];
            out[n + 2] = hexdigits[c & 0x0f];
            n += 3;
        }
    }
    return out[0..n];
}

// ------------------------------------------------------------------ profiles
//
// Kind:0 metadata gives each author a display name and an avatar. The pool
// ingests kind:0 for the feed's authors alongside their notes (the store keeps
// only the newest per author, kind:0 being replaceable); the UI thread parses
// them into this cache during the feed rebuild, keyed by pubkey. The feed reads
// names and avatar image ids from the cache at render time, so a name or a
// just-loaded avatar shows on the next frame without a re-query. Avatars are
// fetched (bounded, cap-aware) and registered as canvas images; the cache is
// UI-thread-only, so no synchronisation is needed.

// Pubkeys a note mentioned that we have no name for. The pool only subscribes
// to the follow set's metadata, so a mention of anyone else would render as a
// bare npub forever; these are fetched separately, once each, and then resolve
// like any other name.
const wanted_profiles_cap = 48;
const WantedProfile = struct {
    used: bool = false,
    requested: bool = false,
    /// How many times this one has been asked for. Some pubkeys simply have no
    /// metadata published anywhere, so the asking is bounded.
    attempts: u8 = 0,
    pubkey: [32]u8 = [_]u8{0} ** 32,
};
/// How many rounds to ask for a mentioned profile before letting it be.
const max_profile_attempts = 3;
var g_wanted = [_]WantedProfile{.{}} ** wanted_profiles_cap;

/// Notes that `pubkey` was mentioned but has no known name yet.
fn wantProfile(pubkey: [32]u8) void {
    if (lookupProfile(pubkey)) |p| {
        if (p.name_len > 0) return;
    }
    for (&g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return;
    }
    for (&g_wanted) |*w| {
        if (!w.used) {
            w.* = .{ .used = true, .pubkey = pubkey };
            return;
        }
    }
    // The set is full. Reclaim a slot from someone we have already asked for the
    // maximum times (no metadata anywhere), so a fresh thread's authors are never
    // starved by a backlog of dead entries. Without this the table fills up once
    // and every later reply author renders as a bare npub forever.
    for (&g_wanted) |*w| {
        if (w.attempts >= max_profile_attempts) {
            w.* = .{ .used = true, .pubkey = pubkey };
            return;
        }
    }
}

/// Whether `pubkey`'s profile is still being fetched: no profile in hand yet, and
/// the wanted-set is still trying (attempts left). This distinguishes "loading"
/// (show a skeleton) from "gave up, or never on the relays" (show nothing), so a
/// handle placeholder does not linger forever for an author with no metadata.
fn profileLoading(pubkey: [32]u8) bool {
    if (lookupProfile(pubkey) != null) return false;
    for (&g_wanted) |*w| {
        if (w.used and std.mem.eql(u8, &w.pubkey, &pubkey)) return w.attempts < max_profile_attempts;
    }
    return false;
}

/// Profile-timer rounds between re-asking for metadata that has not arrived
/// (about 20s at the profile interval).
const profile_rearm_rounds: u64 = 10;
var g_profile_round: u64 = 0;

/// Lets the still-unnamed be asked for again on the next pass.
fn rearmWantedProfiles() void {
    for (&g_wanted) |*w| {
        if (w.used and w.attempts < max_profile_attempts) w.requested = false;
    }
}

/// Asks the relays for the metadata of everyone mentioned but still unnamed, in
/// one batch on a throwaway connection.
fn requestWantedProfiles() void {
    var batch: [wanted_profiles_cap][32]u8 = undefined;
    var n: usize = 0;
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        // Resolved: free the slot so later mentions can use it. Without this the
        // table fills with names we already have and new mentions are dropped.
        if (lookupProfile(w.pubkey)) |p| {
            if (p.name_len > 0) {
                w.* = .{};
                continue;
            }
        }
        if (w.attempts >= max_profile_attempts) continue;
        if (w.requested) continue;
        batch[n] = w.pubkey;
        n += 1;
        w.requested = true;
        w.attempts += 1;
        if (n == batch.len) break;
    }
    if (n == 0) return;
    const thread = std.Thread.spawn(.{}, fetchProfilesOnce, .{ std.heap.page_allocator, batch, n }) catch return;
    thread.detach();
}

/// Fetches kind:0 for `batch` and ingests it, then closes. Its own io backend
/// and signer, like every other background worker.
fn fetchProfilesOnce(gpa: std.mem.Allocator, batch: [wanted_profiles_cap][32]u8, len: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const kinds = [_]u16{0};
    const filters = [_]nostr.filter.Filter{.{ .authors = batch[0..len], .kinds = &kinds, .limit = @intCast(len) }};
    for (relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        relay.subscribe("plaza-mentions", &filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    const store = g_store orelse continue;
                    _ = store.ingest(gpa, e.event, .{ .verify_with = signer }) catch {};
                },
                // Everything stored has been sent; no need to hold the socket.
                .eose => break,
                else => {},
            }
        }
        // Keep going: no single relay holds everyone's metadata, and the store
        // keeps only the newest copy of each anyway.
    }
}

// ------------------------------------------------------------------ quotes
//
// A note can quote another event (NIP-27 `nostr:nevent`/`note`). The quoted
// event's id is decoded once at parse time (Note.quote); this cache holds the
// resolved quoted note (author + a truncated body) keyed by that id, filled from
// the store as it grows and fetched from the pool when absent, mirroring the
// profile cache. The render side reads it to draw an embedded quote card.
const quote_cache_cap = 64;
const max_quote_attempts = 3;
const quote_fetch_batch = 16;
/// Enough of a quoted note to fill the four lines 11f gives it (about 75
/// characters a line at the quote's register), so the clamp decides where the
/// text ends rather than the cache. 64 entries, so the whole table is ~20 KiB.
const quote_text_cap = 320;
/// Where a cached quote is in its life: asked for, in flight, in hand, or asked
/// for enough times that no relay has it.
pub const QuoteState = enum { idle, fetching, loaded, missing };

const QuoteEntry = struct {
    used: bool = false,
    id: [32]u8 = [_]u8{0} ** 32,
    state: QuoteState = .idle,
    attempts: u8 = 0,
    requested: bool = false,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    created_at: i64 = 0,
    text_buf: [quote_text_cap]u8 = [_]u8{0} ** quote_text_cap,
    text_len: u16 = 0,
    /// What the quoted note itself quotes, if anything. Depth stops here (11g):
    /// one hop is a pill saying where it goes, never a third nested body. The
    /// reference is decoded from the event's own content at fill time, because
    /// the stored text is rendered and clamped and can drop the token entirely.
    quote_of: [32]u8 = [_]u8{0} ** 32,
    has_quote_of: bool = false,
    last_used: u64 = 0,
};
var g_quotes = [_]QuoteEntry{.{}} ** quote_cache_cap;
var g_quote_clock: u64 = 0;

/// A link preview: what a page says about itself, for the card 11o draws under a
/// note that links out. Small and fixed, like every other cache here.
const link_title_cap = 96;
const link_desc_cap = 140;
const link_domain_cap = 48;
const link_cache_cap = 32;
/// How many previews may be in flight at once. The SDK has 16 effect slots for
/// everything the app does, so previews take a small, fixed share and wait their
/// turn rather than starving avatars and pictures.
const max_link_fetches = 2;
const max_link_attempts = 2;
/// How far down a thread the link scan reaches. The thread list has no visible
/// range of its own to consult, so it takes the first screenful and stops.
const thread_link_scan_cap: usize = 12;

const LinkPreview = struct {
    used: bool = false,
    /// The URL as written in the note, which is both the key and what a press
    /// opens.
    url_buf: [300]u8 = [_]u8{0} ** 300,
    url_len: u16 = 0,
    state: enum { idle, fetching, loaded, missing } = .idle,
    attempts: u8 = 0,
    requested: bool = false,
    title_buf: [link_title_cap]u8 = [_]u8{0} ** link_title_cap,
    title_len: u8 = 0,
    desc_buf: [link_desc_cap]u8 = [_]u8{0} ** link_desc_cap,
    desc_len: u8 = 0,
    domain_buf: [link_domain_cap]u8 = [_]u8{0} ** link_domain_cap,
    domain_len: u8 = 0,
    last_used: u64 = 0,

    pub fn url(self: *const LinkPreview) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    pub fn title(self: *const LinkPreview) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn description(self: *const LinkPreview) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
    pub fn domain(self: *const LinkPreview) []const u8 {
        return self.domain_buf[0..self.domain_len];
    }
};
var g_links = [_]LinkPreview{.{}} ** link_cache_cap;
var g_link_clock: u64 = 0;

/// The host of a URL, without its `www.`: what the card shows above the title,
/// and what a reader actually checks before pressing.
///
/// The userinfo is CUT, at the last `@`, which is the whole point: a browser
/// does the same, because `https://wirth.ch@evil.tld/` is the oldest phishing
/// shape there is and a card that showed `wirth.ch@evil.tld` would be lending
/// its credibility to whoever wrote the note.
pub fn urlDomain(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    // The port is not part of the name a reader recognises.
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority, ']') == null) authority = authority[0..colon];
    }
    if (std.mem.startsWith(u8, authority, "www.")) authority = authority["www.".len..];
    return authority;
}

/// Whether a link named in a note may be fetched to preview it.
///
/// This is the one place in the app that reaches out to an address a STRANGER
/// chose, unattended, simply because a note scrolled into view. So it is narrow
/// on purpose:
///
///   - https only. Plaintext would put the reader's IP and the exact URL on the
///     wire for anyone on the path, to fetch something nobody asked for.
///   - No userinfo. `std.http.Client` turns it into an `authorization` header,
///     so `http://admin:admin@10.0.0.1/` would have Plaza posting credentials
///     to a host of the note author's choosing.
///   - No private, loopback or link-local address, and no name without a dot.
///     A note must not be able to make every reader's machine probe their own
///     network. Signet's approval API listens on 127.0.0.1 in this very session.
///   - The default port only, so a note cannot aim the reader at a service.
///
/// It cannot stop a redirect INTO one of those (the runtime follows up to
/// three), which is worth knowing and is why the fetch stays unauthenticated and
/// its body is only ever read for two meta tags.
pub fn previewableUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    if (url.len > 300) return false;
    const rest = url["https://".len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0) return false;
    // Userinfo, in any form.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, host, ']') == null) {
            // A port at all means a service, not a site.
            if (colon + 1 < host.len) return false;
            host = host[0..colon];
        } else {
            return false; // a bracketed IPv6 literal is never a site to preview
        }
    }
    for (host) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
    }
    // A bare name (`localhost`, a machine on the LAN) is not a public site.
    const dot = std.mem.lastIndexOfScalar(u8, host, '.') orelse return false;
    if (dot == 0 or dot + 1 >= host.len) return false;
    if (std.ascii.endsWithIgnoreCase(host, ".local") or
        std.ascii.endsWithIgnoreCase(host, ".internal") or
        std.ascii.endsWithIgnoreCase(host, ".localhost")) return false;
    return !isPrivateAddress(host);
}

/// Whether a host is a literal address inside a range that belongs to the
/// reader's own machine or network.
fn isPrivateAddress(host: []const u8) bool {
    var parts: [4]u16 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (n == 4) return false;
        parts[n] = std.fmt.parseInt(u16, part, 10) catch return false;
        if (parts[n] > 255) return false;
        n += 1;
    }
    if (n != 4) return false; // not an IPv4 literal at all
    return switch (parts[0]) {
        0, 10, 127 => true,
        169 => parts[1] == 254, // link-local
        172 => parts[1] >= 16 and parts[1] <= 31,
        192 => parts[1] == 168,
        100 => parts[1] >= 64 and parts[1] <= 127, // carrier-grade NAT
        else => false,
    };
}

/// The first plain link in a note's content: the one the card previews. An image
/// URL is not one (it is drawn as the picture), and neither is anything inside a
/// `nostr:` token.
pub fn firstLinkUrl(content: []const u8, image_url: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (!std.mem.startsWith(u8, content[i..], "https://") and !std.mem.startsWith(u8, content[i..], "http://")) continue;
        if (i > 0 and !std.ascii.isWhitespace(content[i - 1])) continue;
        var j = i;
        while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
        // A trailing sentence mark is punctuation, not part of the address.
        var end = j;
        while (end > i and (content[end - 1] == '.' or content[end - 1] == ',' or content[end - 1] == ')')) end -= 1;
        const candidate = content[i..end];
        if (candidate.len > 300) {
            i = j;
            continue;
        }
        if (image_url.len > 0 and std.mem.eql(u8, candidate, image_url)) {
            i = j;
            continue;
        }
        if (looksLikeImageUrl(candidate)) {
            i = j;
            continue;
        }
        return candidate;
    }
    return null;
}

/// The cache entry for `url`, claimed if it is not already there. Evicts the
/// least recently drawn entry that is not mid-fetch, like the other caches.
fn wantLink(url: []const u8) ?*LinkPreview {
    if (url.len == 0 or url.len > 300) return null;
    for (&g_links) |*l| {
        if (l.used and std.mem.eql(u8, l.url(), url)) return l;
    }
    var victim: ?*LinkPreview = null;
    for (&g_links) |*l| {
        if (!l.used) {
            victim = l;
            break;
        }
        if (l.state == .fetching) continue;
        // Nor one already wanted in THIS pass: a screen with more links than
        // slots would otherwise evict an entry it needs a moment later, reset
        // its state and its attempt count, and re-fetch the same pages from the
        // same strangers' servers on every tick, forever. The media scan learned
        // this the same way.
        if (l.last_used == g_link_clock) continue;
        if (victim == null or l.last_used < victim.?.last_used) victim = l;
    }
    // Nothing free and nothing spare: this link simply goes unpreviewed rather
    // than taking a slot off something on screen.
    const slot = victim orelse return null;
    slot.* = .{ .used = true };
    @memcpy(slot.url_buf[0..url.len], url);
    slot.url_len = @intCast(url.len);
    const host = urlDomain(url);
    const host_len = @min(host.len, slot.domain_buf.len);
    @memcpy(slot.domain_buf[0..host_len], host[0..host_len]);
    slot.domain_len = @intCast(host_len);
    return slot;
}

fn linkFor(url: []const u8) ?*LinkPreview {
    for (&g_links) |*l| {
        if (l.used and std.mem.eql(u8, l.url(), url)) return l;
    }
    return null;
}

/// Asks for the pages the reader can actually see. Gated by the previews
/// setting, like pictures: with it off, no page learns it was linked to.
fn scanLinkFetches(fx: *Effects, model: *const Model) void {
    if (!g_media_previews) return;
    g_link_clock += 1;
    var fired: usize = 0;
    if (model.viewing_thread != 0) {
        // The note being read, and the first screenful under it. Walking the
        // whole conversation would reach out to every host linked anywhere in
        // it, including replies the reader never scrolls to.
        fireLink(fx, &model.thread_root, &fired);
        const shown = @min(model.thread_notes_len, thread_link_scan_cap);
        for (model.thread_notes[0..shown]) |*note| fireLink(fx, note, &fired);
        return;
    }
    const range = model.visibleRange();
    var i = range.first;
    while (i <= range.last and i < model.notes_len) : (i += 1) fireLink(fx, &model.notes[i], &fired);
}

fn fireLink(fx: *Effects, note: *const Note, fired: *usize) void {
    if (!note.hasLink()) return;
    if (!previewableUrl(note.linkUrl())) return;
    const slot = wantLink(note.linkUrl()) orelse return;
    // Stamped first, so the eviction guard above counts this entry as wanted in
    // this pass whatever happens next.
    slot.last_used = g_link_clock;
    if (slot.state != .idle) return;
    if (slot.attempts >= max_link_attempts) {
        slot.state = .missing;
        return;
    }
    if (loadCachedLink(slot)) return;
    if (fired.* >= max_link_fetches) return;
    fired.* += 1;
    slot.state = .fetching;
    slot.attempts += 1;
    const index = (@intFromPtr(slot) - @intFromPtr(&g_links[0])) / @sizeOf(LinkPreview);
    fx.fetch(.{
        .key = link_fetch_key_base + index,
        .url = slot.url(),
        .on_response = Effects.responseMsg(.link_fetched),
    });
}

/// Files what a page said about itself. The body is TRUNCATED at 256 KiB by the
/// runtime and that is fine here, unlike an image: `og:` tags live in the head,
/// so a cut tail costs nothing. Every other handler in this app rejects a
/// truncated body, correctly, because half a picture is garbage.
fn handleLinkFetched(response: native_sdk.EffectResponse) void {
    const index = response.key - link_fetch_key_base;
    if (index >= g_links.len) return;
    const slot = &g_links[index];
    if (!slot.used or slot.state != .fetching) return;
    if (response.outcome == .rejected) {
        // Every effect slot was busy. Not a failure of the page: try again.
        slot.state = .idle;
        slot.attempts -|= 1;
        return;
    }
    if (response.outcome != .ok or response.status < 200 or response.status >= 300) {
        slot.state = if (slot.attempts >= max_link_attempts) .missing else .idle;
        return;
    }
    const meta = parsePageMeta(response.body);
    storeLinkMeta(slot, .{ .title = meta.heading(), .description = meta.description });
    slot.state = if (slot.title_len == 0) .missing else .loaded;
    if (slot.state == .loaded) cacheLink(slot);
}

/// Copies what the page said into the entry's own buffers: the response body is
/// recycled the moment this returns.
fn storeLinkMeta(slot: *LinkPreview, meta: PageMeta) void {
    const title = std.mem.trim(u8, meta.title, " \t\r\n");
    const desc = std.mem.trim(u8, meta.description, " \t\r\n");
    const t = @min(utf8SafeLen(title, slot.title_buf.len), slot.title_buf.len);
    @memcpy(slot.title_buf[0..t], title[0..t]);
    slot.title_len = @intCast(t);
    const d = @min(utf8SafeLen(desc, slot.desc_buf.len), slot.desc_buf.len);
    @memcpy(slot.desc_buf[0..d], desc[0..d]);
    slot.desc_len = @intCast(d);
}

/// `$HOME/.plaza/links/<sha256 of the url>`, holding the three lines the card
/// draws. A preview is worth keeping: the page rarely changes, and a feed
/// re-read from disk should not re-ask the whole web what it said.
fn linkCacheDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza/links", .{home});
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

fn loadCachedLink(slot: *LinkPreview) bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;
    var dir = linkCacheDir(io, environ) catch return false;
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(1024)) catch return false;
    defer gpa.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    const title = lines.next() orelse return false;
    const desc = lines.next() orelse "";
    if (title.len == 0) return false;
    storeLinkMeta(slot, .{ .title = title, .description = desc });
    slot.state = .loaded;
    return true;
}

fn cacheLink(slot: *const LinkPreview) void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = linkCacheDir(io, environ) catch return;
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    var buf: [link_title_cap + link_desc_cap + 4]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "{s}\n{s}\n", .{ slot.title(), slot.description() }) catch return;
    dir.writeFile(io, .{ .sub_path = name, .data = data }) catch return;
}

/// What a page says about itself, read out of its head. Open Graph first, then
/// the plain HTML fallbacks, which is the order every other reader uses.
pub const PageMeta = struct {
    /// The `<title>` tag, kept separately so an Open Graph title can take
    /// precedence without erasing it when it turns out to be empty.
    title: []const u8 = "",
    og_title: []const u8 = "",
    description: []const u8 = "",

    /// What the card shows: the page's chosen title, else the document's.
    pub fn heading(self: PageMeta) []const u8 {
        return if (self.og_title.len > 0) self.og_title else self.title;
    }
};

/// Pulls `og:title`/`og:description` (falling back to `<title>` and
/// `meta name="description"`) out of `html`.
///
/// A deliberately small parser: it walks tags, and inside a `meta` tag it reads
/// the attributes it knows. It does NOT try to be an HTML parser, because it does
/// not have to be: the body arrives capped at 256 KiB, which is where the head
/// lives, and anything it cannot make sense of simply leaves the card without
/// that line rather than guessing.
pub fn parsePageMeta(html: []const u8) PageMeta {
    var out: PageMeta = .{};
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        if (html[i] != '<') continue;
        const rest = html[i + 1 ..];
        if (std.ascii.startsWithIgnoreCase(rest, "title>")) {
            const start = i + 1 + "title>".len;
            const end = std.mem.indexOfPos(u8, html, start, "<") orelse html.len;
            if (out.title.len == 0) out.title = std.mem.trim(u8, html[start..end], " \t\r\n");
            i = end;
            continue;
        }
        if (!std.ascii.startsWithIgnoreCase(rest, "meta")) continue;
        const tag_end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
        const tag = html[i..tag_end];
        const key = metaAttr(tag, "property") orelse metaAttr(tag, "name") orelse {
            i = tag_end;
            continue;
        };
        const content = metaAttr(tag, "content") orelse {
            i = tag_end;
            continue;
        };
        // An EMPTY value is not an answer: a template that renders
        // `content=""` when its Open Graph field is unset must not wipe the
        // page's own title. And the FIRST one wins, so a stray tag in the body
        // cannot override the head.
        if (content.len == 0) {
            i = tag_end;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "og:title")) {
            if (out.og_title.len == 0) out.og_title = content;
        } else if (std.ascii.eqlIgnoreCase(key, "og:description")) {
            if (out.description.len == 0) out.description = content;
        } else if (std.ascii.eqlIgnoreCase(key, "description") and out.description.len == 0) {
            out.description = content;
        }
        i = tag_end;
    }
    return out;
}

/// One attribute's value out of a tag, single or double quoted.
fn metaAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(tag, i, name)) |at| {
        i = at + name.len;
        // A whole attribute name, not a suffix of another one.
        if (at > 0 and (std.ascii.isAlphanumeric(tag[at - 1]) or tag[at - 1] == '-' or tag[at - 1] == ':')) continue;
        var j = i;
        while (j < tag.len and (tag[j] == ' ' or tag[j] == '=')) j += 1;
        if (j >= tag.len) return null;
        const quote = tag[j];
        if (quote != '"' and quote != '\'') continue;
        j += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, j, quote) orelse return null;
        return tag[j..end];
    }
    return null;
}

/// Records that a quoted event `id` needs resolving, deduping and (when full)
/// evicting the least-recently-drawn entry that is not mid-fetch.
fn wantQuote(id: [32]u8) void {
    for (&g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) return;
    }
    for (&g_quotes) |*q| {
        if (!q.used) {
            q.* = .{ .used = true, .id = id };
            return;
        }
    }
    var victim: ?*QuoteEntry = null;
    for (&g_quotes) |*q| {
        if (q.state == .fetching) continue;
        if (victim == null or q.last_used < victim.?.last_used) victim = q;
    }
    // Every slot mid-fetch: still record the newcomer over the overall LRU. The
    // evicted entry's fetch merely ingests into the store, so nothing is lost by
    // dropping its slot, and the new quote is never silently forgotten.
    if (victim == null) {
        for (&g_quotes) |*q| {
            if (victim == null or q.last_used < victim.?.last_used) victim = q;
        }
    }
    if (victim) |v| v.* = .{ .used = true, .id = id };
}

/// The cache entry for a quoted event `id` (marking it drawn this frame so the
/// LRU keeps it), or null when it is not cached.
fn quoteFor(id: [32]u8) ?*QuoteEntry {
    for (&g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) {
            g_quote_clock += 1;
            q.last_used = g_quote_clock;
            return q;
        }
    }
    return null;
}

/// Fills any unresolved quote from the store (it grew, so the fetch may have
/// landed): copies the quoted author and a truncated body, and asks for the
/// author's name. Gives up (marks missing) once every relay has been tried.
fn refreshQuotes(store: *nostr.store.Store) void {
    // The nested references this pass finds, asked for once it is over (see the
    // note where they are collected).
    var nested: [quote_cache_cap][32]u8 = undefined;
    var nested_count: usize = 0;
    for (&g_quotes) |*q| {
        if (!q.used or q.state == .loaded or q.state == .missing) continue;
        var se = (store.getEvent(std.heap.page_allocator, q.id) catch continue) orelse {
            if (q.attempts >= max_quote_attempts) q.state = .missing;
            continue;
        };
        defer se.deinit();
        q.pubkey = se.event.pubkey;
        q.created_at = se.event.created_at;
        var tmp: [note_content_cap]u8 = undefined;
        const omit = firstImageUrl(se.event.content) orelse "";
        const wrote = renderContent(&tmp, se.event.content, omit);
        const keep = utf8SafeLen(tmp[0..wrote], q.text_buf.len);
        @memcpy(q.text_buf[0..keep], tmp[0..keep]);
        q.text_len = @intCast(keep);
        // Decoded from the ORIGINAL content, not the stored text: the stored
        // text is rendered and capped, so the token can be gone from it.
        var probe = Note{};
        const probe_len = @min(se.event.content.len, probe.content_buf.len);
        @memcpy(probe.content_buf[0..probe_len], se.event.content[0..probe_len]);
        probe.content_len = @intCast(probe_len);
        findQuoteRef(&probe);
        q.has_quote_of = probe.quote.kind == .event;
        if (q.has_quote_of) {
            q.quote_of = probe.quote.id;
            // Asked for AFTER this pass, never during it: `wantQuote` writes over
            // whichever slot it evicts, and the entry being filled here is the
            // one it picks first (it is `.idle` and has never been drawn, so its
            // clock is the minimum). Evicting it mid-fill left the nested id
            // cached as loaded with a zero author and an empty body, permanently,
            // because a loaded entry is never retried.
            if (nested_count < nested.len) {
                nested[nested_count] = q.quote_of;
                nested_count += 1;
            }
        }
        q.state = .loaded;
        wantProfile(q.pubkey);
    }
    for (nested[0..nested_count]) |id| wantQuote(id);
}

/// Lets the still-unresolved quotes be asked for again on the next round.
fn rearmWantedQuotes() void {
    for (&g_quotes) |*q| {
        if (q.used and q.state != .loaded and q.state != .missing and q.attempts < max_quote_attempts) q.requested = false;
    }
}

/// Asks the pool for any quoted events not yet in the store, one batch on a
/// throwaway connection, bounded like the mention fetch.
fn requestWantedQuotes() void {
    var batch: [quote_fetch_batch][32]u8 = undefined;
    var n: usize = 0;
    for (&g_quotes) |*q| {
        if (!q.used or q.state == .loaded or q.state == .missing) continue;
        if (q.requested or q.attempts >= max_quote_attempts) continue;
        batch[n] = q.id;
        n += 1;
        q.requested = true;
        q.attempts += 1;
        q.state = .fetching;
        if (n == batch.len) break;
    }
    if (n == 0) return;
    const thread = std.Thread.spawn(.{}, fetchQuotesOnce, .{ std.heap.page_allocator, batch, n }) catch return;
    thread.detach();
}

/// Fetches the quoted events in `batch` by id and ingests them, then closes.
/// The next store-growth tick flips them to `.loaded` via `refreshQuotes`.
fn fetchQuotesOnce(gpa: std.mem.Allocator, batch: [quote_fetch_batch][32]u8, len: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const filters = [_]nostr.filter.Filter{.{ .ids = batch[0..len], .limit = @intCast(len) }};
    for (relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        relay.subscribe("plaza-quotes", &filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    const store = g_store orelse continue;
                    _ = store.ingest(gpa, e.event, .{ .verify_with = signer }) catch {};
                },
                .eose => break,
                else => {},
            }
        }
    }
}

/// Clears the quote cache. For tests, which share the process globals.
pub fn resetQuotesForTest() void {
    g_quotes = [_]QuoteEntry{.{}} ** quote_cache_cap;
    g_quote_clock = 0;
}

/// Builds a Note over `content` and runs the quote-reference scan, so a test can
/// assert what `findQuoteRef` captured (id/off/len) without a live event.
pub fn findQuoteRefForTest(content: []const u8) Note {
    var note = Note{};
    const n = @min(content.len, note.content_buf.len);
    @memcpy(note.content_buf[0..n], content[0..n]);
    note.content_len = @intCast(n);
    findQuoteRef(&note);
    return note;
}

/// Whether the note captured an event quote (for tests).
pub fn noteHasEventQuote(note: *const Note) bool {
    return note.quote.kind == .event;
}

/// A cached author profile.
const Profile = struct {
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
    // The registered canvas-image id for this profile's avatar (0 = none). NOT
    // fixed per cache slot: there are only `max_avatar_images` registry ids for
    // far more cached authors, so ids are lent to whoever is on screen now and
    // reclaimed from whoever scrolled away (see `assignAvatarSlots`).
    image_id: u64 = 0,
    // The last avatar pass this author was on screen, so the id LRU evicts the
    // least-recently-seen author when it needs a slot for a new one.
    avatar_clock: u64 = 0,

    fn name(self: *const Profile) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn username(self: *const Profile) []const u8 {
        return self.username_buf[0..self.username_len];
    }
    fn nip05(self: *const Profile) []const u8 {
        return self.nip05_buf[0..self.nip05_len];
    }
    fn picture(self: *const Profile) []const u8 {
        return self.picture_buf[0..self.picture_len];
    }
    fn url(self: *const Profile) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

var g_profiles = [_]Profile{.{}} ** profile_cap;

// The avatar-id LRU clock (see `assignAvatarSlots`): bumped once per avatar
// pass; a profile's `avatar_clock` records the last pass it was on screen.
var g_avatar_clock: u64 = 0;

// Bumped whenever a profile gains or changes a display name. Mention labels are
// baked into note text at parse time, so the feed re-parses (rather than
// reuses) its notes when this moves; author lines resolve live and never need it.
var g_names_generation: u64 = 0;

/// Clears the profile cache. For tests, which share the process globals.
pub fn resetProfilesForTest() void {
    g_profiles = [_]Profile{.{}} ** profile_cap;
    g_names_generation = 0;
    g_notes_names_generation = 0;
    g_avatar_clock = 0;
}

/// Marks `pubkey`'s profile as having (or not having) a kind:0 picture, so a
/// test can exercise the avatar-id LRU without a real fetch.
pub fn setProfilePictureForTest(pubkey: [32]u8, present: bool) void {
    const p = upsertProfile(pubkey) orelse return;
    p.picture_len = if (present) 8 else 0;
    if (present) @memcpy(p.picture_buf[0..8], "http://x");
}

/// The registry image id currently lent to `pubkey`'s avatar (0 = none). For
/// tests of the id LRU.
pub fn avatarImageIdForTest(pubkey: [32]u8) u64 {
    const p = lookupProfile(pubkey) orelse return 0;
    return p.image_id;
}

/// Runs one avatar-id assignment pass, for tests.
pub fn assignAvatarSlotsForTest(fx: *Effects, model: *const Model) void {
    assignAvatarSlots(fx, model);
}

// The notes this session has liked, so the heart renders filled and an un-like
// knows which reaction (kind:7) to delete. In-memory: a returning session
// rediscovers its likes from the ingested crowd reactions (PR-7 dedupes by
// reactor), so this is the optimistic layer, not the source of truth.
const my_likes_cap = 512;
const MyLike = struct {
    used: bool = false,
    note_id: i64 = 0,
    // The id of our own kind:7 reaction, e-tagged by the kind:5 that un-likes it.
    reaction_id: [32]u8 = [_]u8{0} ** 32,
};
var g_my_likes = [_]MyLike{.{}} ** my_likes_cap;

/// Whether this session has liked `note_id`.
fn isLiked(note_id: i64) bool {
    return likeEntry(note_id) != null;
}

/// The like record for `note_id`, or null.
fn likeEntry(note_id: i64) ?*MyLike {
    for (&g_my_likes) |*e| {
        if (e.used and e.note_id == note_id) return e;
    }
    return null;
}

/// Records a like on `note_id` with our reaction's id, so the heart fills and an
/// un-like can find the reaction. Silently drops when the table is full (the
/// like still publishes; only the optimistic bookkeeping is skipped).
fn rememberLike(note_id: i64, reaction_id: [32]u8) void {
    if (likeEntry(note_id)) |e| {
        e.reaction_id = reaction_id;
        return;
    }
    for (&g_my_likes) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .note_id = note_id, .reaction_id = reaction_id };
            return;
        }
    }
}

/// Drops the like on `note_id`, returning its reaction id (to e-tag the un-like).
fn forgetLike(note_id: i64) ?[32]u8 {
    if (likeEntry(note_id)) |e| {
        const id = e.reaction_id;
        e.* = .{};
        return id;
    }
    return null;
}

/// Clears the like table. For tests, which share the process globals.
pub fn resetLikesForTest() void {
    g_my_likes = [_]MyLike{.{}} ** my_likes_cap;
}

/// Whether this session has liked the note (for tests and the view).
pub fn isLikedForTest(note_id: i64) bool {
    return isLiked(note_id);
}

// ------------------------------------------------------------ engagement counts
//
// Reply / repost / like / zap tallies per feed note, aggregated client-side (no
// NIP-45 COUNT, whose relay support is spotty). Each ingest thread opens a second
// subscription, `{kinds:[1,6,7,9735], "#e":[the notes it loaded]}`, and folds the
// arriving events into this in-memory table, deduped across relays by event id.
// The view reads it at render time. Counts are per session: a relaunch refetches
// them, so nothing here is persisted.

// Above the displayed feed so the union of the relays' watched sets fits with
// room to spare; a full table then only degrades gracefully (see ensureEngagement).
const engagement_cap = 512;
const Counts = struct {
    replies: u32 = 0,
    reposts: u32 = 0,
    likes: u32 = 0,
    zap_msat: u64 = 0,
};
const Engagement = struct {
    used: bool = false,
    note_id: i64 = 0,
    counts: Counts = .{},
    /// Which relays in the pool have delivered this note, one bit each. The
    /// thread's focal line reports the count, so the claim "seen on 4 relays" is
    /// a measurement rather than a guess. A pool wider than the mask simply stops
    /// counting past bit 63, which no configuration reaches today.
    relays_seen: u64 = 0,
};
var g_engagement = [_]Engagement{.{}} ** engagement_cap;

// Cross-relay dedup: a bounded open-addressing set of event-id prefixes (the
// first 8 bytes as a u64; 0 marks an empty slot, so the ~1-in-2^64 all-zero
// prefix is simply never deduped). When it fills, new ids stop being recorded
// and a reaction seen on two relays can double-count; sized far above a starter
// pack feed's traffic so that is only a theoretical tail.
const seen_engagement_cap = 1 << 15;
var g_seen = [_]u64{0} ** seen_engagement_cap;
var g_seen_len: usize = 0;

/// Notes that this relay has now delivered. Called from each relay's ingest
/// thread as the event lands, so the count is of relays that ACTUALLY sent it.
fn markRelaySeen(note_id: i64, relay_index: usize) void {
    if (relay_index >= 64) return;
    const bit = @as(u64, 1) << @intCast(relay_index);
    engagementLock();
    defer engagementUnlock();
    // Only a note the table ALREADY tracks. Creating a row here would spend the
    // 512-row budget on every note the pool delivers, crowding out the counts the
    // rows exist for; the engagement subscription creates the rows for the notes
    // on screen, which are the only ones whose spread can be read.
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) {
            e.relays_seen |= bit;
            return;
        }
    }
}

/// How many relays have delivered `note_id`, or 0 when it has not been tracked
/// (a note read straight from the store on a cold start was delivered by nobody
/// this session, and the focal line says nothing rather than "seen on 0 relays").
pub fn relaysSeenFor(note_id: i64) usize {
    engagementLock();
    defer engagementUnlock();
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) return @popCount(e.relays_seen);
    }
    return 0;
}

var g_engagement_lock = std.atomic.Value(bool).init(false);
fn engagementLock() void {
    while (g_engagement_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn engagementUnlock() void {
    g_engagement_lock.store(false, .release);
}

/// The u64 dedup key for an event id (its first 8 bytes, big-endian).
fn idPrefix(id: [32]u8) u64 {
    return std.mem.readInt(u64, id[0..8], .big);
}

/// Whether `prefix` is already in the seen set. Caller holds the lock. The probe
/// count is bounded by the table size so a full table cannot spin.
fn seenContains(prefix: u64) bool {
    if (prefix == 0) return false;
    var i = prefix % seen_engagement_cap;
    var probes: usize = 0;
    while (g_seen[i] != 0 and probes < seen_engagement_cap) : ({
        i = (i + 1) % seen_engagement_cap;
        probes += 1;
    }) {
        if (g_seen[i] == prefix) return true;
    }
    return false;
}

/// Records `prefix` as seen and returns true if it was new (not a cross-relay
/// duplicate). Caller holds the lock. A full set (or the ~1-in-2^64 zero prefix)
/// reports NOT-new, so counting stops rather than double-counting: reporting new
/// there would fold an event into the crowd total that `seenContains` can never
/// confirm, breaking the own-like reconciliation. Sized far above a feed's
/// traffic so this "stop counting" tail is only theoretical.
fn markSeen(prefix: u64) bool {
    if (prefix == 0 or g_seen_len >= seen_engagement_cap) return false;
    var i = prefix % seen_engagement_cap;
    while (g_seen[i] != 0) : (i = (i + 1) % seen_engagement_cap) {
        if (g_seen[i] == prefix) return false;
    }
    g_seen[i] = prefix;
    g_seen_len += 1;
    return true;
}

/// The counts row for `note_id`, creating it if there is room. Caller holds the
/// lock. Null only when the table is full of other notes.
fn ensureEngagement(note_id: i64) ?*Engagement {
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) return e;
    }
    for (&g_engagement) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .note_id = note_id };
            return e;
        }
    }
    return null;
}

/// The crowd counts for `note_id` (zeroes if none). Read at render time.
pub fn engagementFor(note_id: i64) Counts {
    engagementLock();
    defer engagementUnlock();
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) return e.counts;
    }
    return .{};
}

/// The like count to display for a note: the crowd's likes plus this session's
/// own optimistic +1, dropped once our reaction (`my_reaction`) has come back
/// through the subscription and is folded into the crowd total. Both reads
/// happen under one lock hold, so the two never disagree across a concurrent
/// count (which would flicker the number for a frame).
pub fn likeCountFor(note_id: i64, my_reaction: ?[32]u8) u64 {
    engagementLock();
    defer engagementUnlock();
    var crowd: u32 = 0;
    for (&g_engagement) |*e| {
        if (e.used and e.note_id == note_id) {
            crowd = e.counts.likes;
            break;
        }
    }
    const mine: u64 = if (my_reaction) |rid| (if (seenContains(idPrefix(rid))) 0 else 1) else 0;
    return @as(u64, crowd) + mine;
}

/// Whether a kind:7 reaction's content counts as a like: NIP-25 treats "+" and
/// empty as a like, and "-" (a downvote) and emoji/shortcode as something else.
fn isLikeReaction(content: []const u8) bool {
    return content.len == 0 or std.mem.eql(u8, content, "+");
}

/// The millisats a bolt11 invoice encodes, or 0 when it carries no amount. The
/// human-readable part is everything before the bech32 separator (the only '1',
/// since the data charset excludes it); the amount is its digits times the
/// optional multiplier, scaled to msat (1 BTC = 1e11 msat).
pub fn bolt11Msat(invoice: []const u8) u64 {
    if (!std.mem.startsWith(u8, invoice, "ln")) return 0;
    const sep = std.mem.lastIndexOfScalar(u8, invoice, '1') orelse return 0;
    const hrp = invoice[0..sep];
    var i: usize = 2; // past "ln"
    while (i < hrp.len and !std.ascii.isDigit(hrp[i])) i += 1; // past the currency
    const start = i;
    while (i < hrp.len and std.ascii.isDigit(hrp[i])) i += 1;
    if (i == start) return 0; // an amountless "any amount" invoice
    const num = std.fmt.parseInt(u64, hrp[start..i], 10) catch return 0;
    const mult: u8 = if (i < hrp.len) hrp[i] else 0;
    return switch (mult) {
        'm' => num *| 100_000_000,
        'u' => num *| 100_000,
        'n' => num *| 100,
        'p' => num / 10,
        0 => num *| 100_000_000_000,
        else => 0,
    };
}

/// The sats a kind:9735 zap receipt is worth, from its bolt11 tag.
fn zapMsat(ev: nostr.event.Event) u64 {
    for (ev.tags) |tag| {
        if (tag.len >= 2 and std.mem.eql(u8, tag[0], "bolt11")) return bolt11Msat(tag[1]);
    }
    return 0;
}

/// The single note an engagement event is about: its `reply`-marked e tag if it
/// has one (NIP-10), else its last e tag (NIP-25 says a reaction's target is the
/// last e tag; the same positional convention names a reply's direct parent).
/// Counting only this one, rather than every e tag, keeps a threaded reply from
/// crediting the whole ancestor chain and dedupes an id repeated across tags.
fn engagementTarget(ev: nostr.event.Event) ?[]const u8 {
    var last_e: ?[]const u8 = null;
    var reply_e: ?[]const u8 = null;
    for (ev.tags) |tag| {
        if (tag.len < 2 or tag[0].len != 1 or tag[0][0] != 'e') continue;
        last_e = tag[1];
        if (tag.len >= 4 and std.mem.eql(u8, tag[3], "reply")) reply_e = tag[1];
    }
    return reply_e orelse last_e;
}

/// Folds one engagement event into the count of the single note it targets, when
/// that note is in this relay thread's loaded set. The cross-relay dedup
/// (`markSeen`) happens only AFTER the target is confirmed present here and a row
/// is in hand, so an event a thread cannot place does not consume the dedup slot
/// (which would let its true owner drop it) and a full table cannot mark an event
/// seen-but-uncounted (which would break the own-like reconciliation).
fn countEngagement(ev: nostr.event.Event, feed_ids: []const i64) void {
    // A reaction that is not a like ("+") adds nothing.
    if (ev.kind == 7 and !isLikeReaction(ev.content)) return;
    const target_hex = engagementTarget(ev) orelse return;
    const target = noteIdFromHex(target_hex) orelse return;

    engagementLock();
    defer engagementUnlock();
    var in_feed = false;
    for (feed_ids) |fid| {
        if (fid == target) {
            in_feed = true;
            break;
        }
    }
    if (!in_feed) return;
    const row = ensureEngagement(target) orelse return;
    if (!markSeen(idPrefix(ev.id))) return;
    switch (ev.kind) {
        1 => row.counts.replies += 1,
        6, 16 => row.counts.reposts += 1,
        7 => row.counts.likes += 1,
        9735 => row.counts.zap_msat +|= zapMsat(ev),
        else => {},
    }
}

/// Parses a 64-char hex event id's first 8 bytes into the same non-negative i64
/// key `noteIdOf` derives, so an `e` tag maps onto a loaded note. Null when the
/// value is not at least 16 hex digits.
fn noteIdFromHex(hex: []const u8) ?i64 {
    if (hex.len < 16) return null;
    var bytes: [8]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex[0..16]) catch return null;
    return @intCast(std.mem.readInt(u64, &bytes, .big) & std.math.maxInt(i64));
}

/// Clears the engagement table and dedup set. For tests.
pub fn resetEngagementForTest() void {
    g_engagement = [_]Engagement{.{}} ** engagement_cap;
    g_seen = [_]u64{0} ** seen_engagement_cap;
    g_seen_len = 0;
}

/// Folds an event into the counts, for tests (the ingest path without threads).
pub fn countEngagementForTest(ev: nostr.event.Event, feed_ids: []const i64) void {
    countEngagement(ev, feed_ids);
}

/// Finds the cached profile for `pubkey`, or null.
fn lookupProfile(pubkey: [32]u8) ?*Profile {
    for (&g_profiles) |*p| {
        if (p.used and std.mem.eql(u8, &p.pubkey, &pubkey)) return p;
    }
    return null;
}

/// The cache slot for `pubkey`, allocating a free one on first sight, else
/// reusing the least-recently-seen slot. Avatar image ids are NOT tied to the
/// slot here (see `assignAvatarSlots`); a new slot starts with none and earns
/// one only while on screen.
pub fn upsertProfile(pubkey: [32]u8) ?*Profile {
    if (lookupProfile(pubkey)) |p| return p;
    for (&g_profiles) |*p| {
        if (!p.used) {
            p.* = .{ .used = true, .pubkey = pubkey };
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
        if (p.avatar_clock == g_avatar_clock) continue;
        if (victim == null or p.avatar_clock < victim.?.avatar_clock) victim = p;
    }
    const v = victim orelse return null;
    v.* = .{ .used = true, .pubkey = pubkey };
    return v;
}

/// Parses a kind:0 metadata JSON content into `profile`'s name and picture.
/// Tolerant: unknown fields are ignored and a malformed blob leaves the profile
/// unchanged (it just keeps rendering from its npub). Prefers `display_name`
/// (or the legacy `displayName`) over `name`.
pub fn parseMetadataInto(profile: *Profile, content: []const u8) void {
    const Metadata = struct {
        name: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
        displayName: ?[]const u8 = null,
        picture: ?[]const u8 = null,
        nip05: ?[]const u8 = null,
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
        const n = utf8SafeLen(trimmed, profile.name_buf.len);
        @memcpy(profile.name_buf[0..n], trimmed[0..n]);
        profile.name_len = @intCast(n);
        break;
    }
    // The username is kept separately: it is the handle line under a display
    // name, and collapsing the two fields into one left that line empty for every
    // author without a NIP-05.
    if (md.name) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            const n = utf8SafeLen(trimmed, profile.username_buf.len);
            @memcpy(profile.username_buf[0..n], trimmed[0..n]);
            profile.username_len = @intCast(n);
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
            }
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

/// Wall-clock seconds on the UI thread, or 0 before `main` wires the clock.
fn nowSeconds() i64 {
    const io = g_io orelse return 0;
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// The pubkey Plaza posts as: the local key, or the remote signer's, or null
/// before an identity is established. The feed includes it so your own notes
/// show alongside the follows you read.
fn activePubkey() ?[32]u8 {
    return switch (g_signer_kind) {
        .local => if (g_identity_kp) |kp| kp.public_key else null,
        .remote => g_remote_pubkey,
        .helper => if (g_helper_has_identity) g_helper_identity_pk else null,
    };
}

// ------------------------------------------------------------------ model

/// A `nostr:nevent`/`note` quote a note carries: the decoded event id (the
/// fetch, open, and cache key) and the byte span of its raw token within the
/// note's `content_buf`, so the body can be split around it at render time
/// without ever mutating the stored text.
const QuoteRef = struct {
    kind: enum(u8) { none, event } = .none,
    id: [32]u8 = [_]u8{0} ** 32,
    off: u16 = 0,
    len: u16 = 0,
};

/// One note as the feed renders it: a two-letter avatar, the author's
/// abbreviated npub, a relative timestamp, and the (truncated) content. Strings
/// are copied into fixed buffers so a card never aliases the query arena it was
/// built from.
pub const Note = struct {
    // Non-negative i64: the markup engine holds a `for each` integer key as i64
    // then casts it to u64, so a raw u64 (or negative i64) from the id's high
    // bytes would overflow and panic. Mask off the sign bit.
    id: i64 = 0,
    // The full 32-byte event id, for the reaction's `e` tag and the engagement
    // subscription's `#e` filter. The i64 above is only a render/dedup key.
    event_id: [32]u8 = [_]u8{0} ** 32,
    created_at: i64 = 0,
    // The author's full pubkey, so the view can resolve a display name and an
    // avatar from the profile cache at render time (picking up a name or a
    // just-loaded avatar without rebuilding the note).
    pubkey: [32]u8 = [_]u8{0} ** 32,
    initials_buf: [2]u8 = [_]u8{0} ** 2,
    author_buf: [24]u8 = [_]u8{0} ** 24,
    author_len: u8 = 0,
    time_buf: [12]u8 = [_]u8{0} ** 12,
    time_len: u8 = 0,
    content_buf: [note_content_cap]u8 = [_]u8{0} ** note_content_cap,
    content_len: u16 = 0,
    // The first image URL in the note, lifted out of the text and rendered as a
    // picture instead (see `renderContent`'s `omit`).
    image_url_buf: [300]u8 = [_]u8{0} ** 300,
    image_url_len: u16 = 0,
    // Height divided by width, taken from the note's own NIP-92 `imeta dim`
    // when it carries one. Knowing the shape BEFORE the picture downloads is
    // what lets the card reserve exactly the right space, so nothing shifts
    // when the image arrives (or is evicted and comes back).
    image_aspect: f32 = 0,
    /// What the picture's own chrome says: its pixel dimensions, from the same
    /// `imeta` tag the aspect comes from, and its alt text. Both are the note
    /// author's claim about the file, which is the only thing available before
    /// the bytes are, and the chips read at rest rather than on hover (the
    /// design's hover-expand is not expressible).
    image_w: u16 = 0,
    image_h: u16 = 0,
    image_bytes: u32 = 0,
    /// The picture's blurhash, when the note carries one: its colour before its
    /// bytes. Fixed buffer, because the tag's memory is the event's.
    image_blur_buf: [40]u8 = [_]u8{0} ** 40,
    image_blur_len: u8 = 0,
    /// The first plain link in the note, previewed as a card under the body. One
    /// per note, which is what 11o draws; the URL stays in the text as well.
    link_url_buf: [300]u8 = [_]u8{0} ** 300,
    link_url_len: u16 = 0,
    /// Whether the note described its picture. The chip is the marker the shot
    /// draws, one word: the description itself would need a hover expand, which
    /// is not expressible.
    image_has_alt: bool = false,
    // The first `nostr:nevent`/`note` reference in the content, decoded once at
    // parse time: the quoted event id, and the byte span of its raw token in
    // `content_buf` so the body can split around it and render an embedded quote
    // card. `.none` when the note quotes nothing.
    quote: QuoteRef = .{},
    // The NIP-10 parent this note answers (the `e` tag marked `reply`, or the
    // thread root for a direct reply), extracted once at parse time so a thread
    // can seat each reply under the note it answers. Zero when it answers
    // nothing; the flag disambiguates a genuine all-zero id.
    reply_parent: [32]u8 = [_]u8{0} ** 32,
    has_reply_parent: bool = false,
    // Thread placement, stamped by `arrangeThread`: how deep this reply sits
    // under the root (1 = a direct reply). Meaningless outside an arranged
    // thread.
    depth: u8 = 0,
    // Which build of the open thread this reply first appeared in, so a late
    // arrival sorts after what is already on screen instead of jumping into the
    // middle of it. Only meaningful for a thread's replies.
    arrival: u32 = 0,

    pub fn initials(self: *const Note) []const u8 {
        return &self.initials_buf;
    }
    /// The picture's blurhash, empty when the note carries none.
    pub fn imageBlurhash(self: *const Note) []const u8 {
        return self.image_blur_buf[0..self.image_blur_len];
    }
    /// The link this note previews, empty when it has none.
    pub fn linkUrl(self: *const Note) []const u8 {
        return self.link_url_buf[0..self.link_url_len];
    }
    pub fn hasLink(self: *const Note) bool {
        return self.link_url_len > 0;
    }
    /// Whether this note carries an image to render.
    pub fn hasImage(self: *const Note) bool {
        return self.image_url_len > 0;
    }
    /// What the picture's chip says: its dimensions and its weight, as the note
    /// claims them, in the shot's own form (`1600x900 · 240 KB`). Either half may
    /// be missing, and the chip is empty when both are. Never taken from the
    /// decoded bytes, which are the proxy's 480px box and would be a lie about
    /// the file, and never from the response, which carries no headers.
    pub fn imageChipLabel(self: *const Note, arena: std.mem.Allocator) []const u8 {
        const has_dims = self.image_w > 0 and self.image_h > 0;
        if (has_dims and self.image_bytes > 0) {
            return std.fmt.allocPrint(arena, "{d}\u{00d7}{d} · {s}", .{ self.image_w, self.image_h, byteSize(arena, self.image_bytes) }) catch "";
        }
        if (has_dims) return std.fmt.allocPrint(arena, "{d}\u{00d7}{d}", .{ self.image_w, self.image_h }) catch "";
        if (self.image_bytes > 0) return byteSize(arena, self.image_bytes);
        return "";
    }
    /// The note's image URL (empty when it has none).
    pub fn imageUrl(self: *const Note) []const u8 {
        return self.image_url_buf[0..self.image_url_len];
    }
    /// The registered image id for this note's picture, or 0 while it is
    /// loading, unavailable, or absent.
    pub fn media_id(self: *const Note) u64 {
        if (mediaSlotFor(self.id)) |m| {
            if (m.state == .loaded) return m.image_id;
        }
        return 0;
    }
    /// The author's display name from their kind:0 profile, or the abbreviated
    /// npub until (or unless) a profile is known.
    pub fn author(self: *const Note) []const u8 {
        if (lookupProfile(self.pubkey)) |p| {
            if (p.name_len > 0) return p.name();
        }
        return self.author_buf[0..self.author_len];
    }
    /// The registered avatar image id for this author, or 0 to draw initials.
    pub fn avatar_id(self: *const Note) u64 {
        if (lookupProfile(self.pubkey)) |p| {
            if (p.avatar_state == .loaded) return p.image_id;
        }
        return 0;
    }
    /// The @handle for the identity line: the author's NIP-05, shown as `@name`
    /// (or `@domain` for the root `_@domain` form). Empty when they have no
    /// NIP-05 (a bare npub is not a handle, so nothing is shown rather than
    /// `@npub…`. Allocated in the caller's arena for the frame.
    /// The handle shown under the name, and whether it is a NIP-05 identity.
    ///
    /// A NIP-05 is the real thing and reads in the identity violet: `@user`, or
    /// `@domain` for the root `_@domain` form. Without one there is still a
    /// second line, because the identity block is pinned to the disc's height and
    /// an empty half looks like a loading bug: the kind:0 name stands in, and
    /// failing that a short npub, both MUTED so the violet keeps meaning "this
    /// name is attested somewhere".
    pub fn handleLabel(self: *const Note, arena: std.mem.Allocator) struct { text: []const u8, nip05: bool } {
        if (lookupProfile(self.pubkey)) |p| {
            if (p.nip05_len > 0) {
                const id = p.nip05();
                if (std.mem.indexOfScalar(u8, id, '@')) |at| {
                    const local = id[0..at];
                    const domain = id[at + 1 ..];
                    const shown = if (std.mem.eql(u8, local, "_")) domain else local;
                    if (shown.len > 0) {
                        return .{ .text = std.fmt.allocPrint(arena, "@{s}", .{shown}) catch "", .nip05 = true };
                    }
                }
            }
            // No NIP-05, so the kind:0 username stands in, muted: violet is
            // reserved for an identity attested somewhere. It is skipped when it
            // would only echo the name line above it (a profile whose display
            // name IS its username), because the same string twice reads as a
            // rendering bug rather than as a handle.
            const user = p.username();
            if (user.len > 0 and !std.mem.eql(u8, user, p.name())) {
                return .{ .text = std.fmt.allocPrint(arena, "@{s}", .{user}) catch "", .nip05 = false };
            }
        }
        return .{ .text = "", .nip05 = false };
    }

    pub fn handle(self: *const Note, arena: std.mem.Allocator) []const u8 {
        const p = lookupProfile(self.pubkey) orelse return "";
        if (p.nip05_len == 0) return "";
        const id = p.nip05();
        const at = std.mem.indexOfScalar(u8, id, '@') orelse return "";
        const local = id[0..at];
        const domain = id[at + 1 ..];
        const shown = if (std.mem.eql(u8, local, "_")) domain else local;
        if (shown.len == 0) return "";
        return std.fmt.allocPrint(arena, "@{s}", .{shown}) catch "";
    }
    /// Whether this author's NIP-05 has been verified (well-known JSON maps the
    /// name back to their pubkey). Only then does the identity line show a check.
    pub fn verified(self: *const Note) bool {
        if (lookupProfile(self.pubkey)) |p| return p.nip05_state == .verified;
        return false;
    }
    pub fn time(self: *const Note) []const u8 {
        return self.time_buf[0..self.time_len];
    }
    pub fn content(self: *const Note) []const u8 {
        return self.content_buf[0..self.content_len];
    }

    /// (Re)computes the relative timestamp against `now_s`. Cheap and
    /// allocation-free, so the UI can freshen every tick without a re-query.
    fn setTime(self: *Note, now_s: i64) void {
        const dt = now_s - self.created_at;
        const written = (if (dt < 60)
            std.fmt.bufPrint(&self.time_buf, "now", .{})
        else if (dt < 3600)
            std.fmt.bufPrint(&self.time_buf, "{d}m", .{@divTrunc(dt, 60)})
        else if (dt < 86_400)
            std.fmt.bufPrint(&self.time_buf, "{d}h", .{@divTrunc(dt, 3600)})
        else if (dt < 604_800)
            std.fmt.bufPrint(&self.time_buf, "{d}d", .{@divTrunc(dt, 86_400)})
        else
            std.fmt.bufPrint(&self.time_buf, "{d}w", .{@divTrunc(dt, 604_800)})) catch return;
        self.time_len = @intCast(written.len);
    }
};

/// Which top-level screen the app shows.
const Stage = enum { onboarding, ready, settings };

pub const Model = struct {
    notes: [feed_capacity]Note = [_]Note{.{}} ** feed_capacity,
    notes_len: usize = 0,
    live_relays: usize = 0,
    /// Which chrome menu is open, if any. One at a time: opening one closes the
    /// rest, and Escape or a press outside closes whatever is open.
    menu: ChromeMenu = .none,
    /// Notes still owed to the relays, sampled on the tick: the queue itself is
    /// written by the publisher's thread, so the view reads this snapshot rather
    /// than the queue, and one frame never disagrees with itself.
    outbox_pending: usize = 0,
    outbox_stuck: usize = 0,
    /// Whether a level is showing its replies from outside the follow graph, and
    /// how many pages of replies it has revealed. PER LEVEL, indexed like the
    /// back-stack: a level stays mounted while the reader walks into a reply and
    /// back, and it has to come back the size it was. One shared pair of flags
    /// collapsed a parent's revealed pages on the way back, under a scroll offset
    /// restored for the taller list.
    thread_outside_open: [thread_depth_max + 1]bool = [_]bool{false} ** (thread_depth_max + 1),
    thread_page: [thread_depth_max + 1]usize = [_]usize{1} ** (thread_depth_max + 1),
    /// Whether the reader has paused the pool. Reading keeps working: the store
    /// is the app, so a pause stops the sockets, not the feed.
    relays_paused: bool = false,
    offline_relays: usize = 0,
    // The composer's edit state (text + caret + selection). The view binds the
    // text through `draft()`, never the buffer itself, and every edit event is
    // mirrored here in `update`.
    draft_buffer: canvas.TextBuffer(compose_capacity) = .{},
    // Which screen shows. A returning user (session on disk) starts at `.ready`;
    // a newcomer starts at `.onboarding` and moves to `.ready` when they sign in.
    // `.settings` is reached from the feed and returns to it.
    stage: Stage = .onboarding,
    // The onboarding sign-in field: an existing `nsec` to import a key, or a
    // `bunker://` URL to pair with an external NIP-46 signer (Signet).
    login_buffer: canvas.TextBuffer(220) = .{},
    // Settings: whether the "log out" confirmation is showing, and whether the
    // local secret key is revealed for backup.
    logout_pending: bool = false,
    reveal_nsec: bool = false,
    // The media-proxy field in Settings (see `g_media_proxy_buf`).
    proxy_buffer: canvas.TextBuffer(200) = .{},
    proxy_saved: bool = false,
    // Which note's picture is expanded to fill the window, if any.
    expanded_note: ?i64 = null,
    // Whether the compose sheet is open. Compose is on demand from the "New
    // note" button in the titlebar, not a permanent bar, so the feed fills the
    // window.
    composing: bool = false,
    // Whether the guest dismissed the join strip this session. Dismissal only
    // hides the strip; the join surface stays reachable through every gated
    // verb and the status bar's Guest chip.
    guest_strip_dismissed: bool = false,
    // Whether the first-intent join sheet is up (the ladder: create, bring a
    // key, use a signer). Rises when a guest presses a gated verb, or from the
    // strip and the Guest chip.
    joining: bool = false,
    // The remembered intent: the guest reached for the composer, so composing
    // opens by itself the moment an identity exists. The sheet says so.
    pending_compose: bool = false,
    // The other remembered intent: the guest reached for a like. The note id is
    // held here (0 = none) so the like completes the moment an identity exists.
    pending_like: i64 = 0,
    // Whether the join sheet is on its focused bunker-input step (chose "Use
    // your own signer") rather than the ladder.
    bunker_mode: bool = false,
    // The open thread: the focused note's id (0 = the feed, not a thread). When
    // set, the thread is layered OVER the feed (which stays mounted, so its
    // scroll offset survives) with the note and its replies.
    viewing_thread: i64 = 0,
    // The open thread's root, snapshotted so it survives a store rebuild and a
    // reply can be opened as its own thread. Valid while viewing_thread != 0.
    thread_root: Note = .{},
    // The open thread's replies, cached from the store so they are pressable
    // (open as a sub-thread), get their pictures fetched, and hold across
    // rebuilds. Rebuilt each tick, oldest first.
    thread_notes: [thread_reply_cap]Note = [_]Note{.{}} ** thread_reply_cap,
    thread_notes_len: usize = 0,
    // The back-stack of thread roots: opening a reply as a sub-thread pushes the
    // current root, so Back returns to it, and only the last Back returns to the
    // feed.
    thread_stack: [thread_depth_max]Note = [_]Note{.{}} ** thread_depth_max,
    thread_stack_len: usize = 0,
    // Whether the first reply fetch is still out with nothing in hand, so the
    // thread shows skeleton rows rather than looking empty under the root.
    thread_loading: bool = false,
    // The open thread's fetch generation and when it opened, so the loading
    // skeletons retire the moment THIS thread's fetch reports back (or a grace
    // period elapses), never on a stale earlier thread's completion.
    thread_seq: u64 = 0,
    thread_open_at: i64 = 0,
    // The reply composer's edit state, bound through `reply_draft`.
    reply_buffer: canvas.TextBuffer(compose_capacity) = .{},
    // The name beat: after creating an identity, one optional, skippable ask
    // so the account is not blank. Never for imported keys or signers.
    naming: bool = false,
    name_buffer: canvas.TextBuffer(64) = .{},
    // A small confirming toast ("Posted", "Name set"), cleared by the tick.
    toast_buf: [48]u8 = undefined,
    toast_len: usize = 0,
    toast_until: i64 = 0,
    // The backup nudge after the first local-key post this session: calm,
    // dismissible, stakes stated plainly.
    backup_nudge: bool = false,
    backup_nudge_dismissed: bool = false,
    // Where the feed is scrolled, so images load around the viewport instead of
    // only at the top. The windowed list replaces this estimate with the
    // runtime's exact visible range in the next milestone.
    feed_scroll: canvas.ScrollState = .{},
    // How many notes the feed currently asks the store for; grows a page at a
    // time as the reader reaches the end.
    feed_limit: usize = feed_page,

    // These fields reach the view only through methods, `notes`/`notes_len`
    // through `note_list`/`has_notes`/`footer`, the relay counts through the
    // status line, the draft through `draft`/`draft_empty`, the stage through
    // `show_onboarding`/`show_feed`/`show_settings`, the login field through
    // `login_draft`, so the raw fields are never bound by name.
    // Everything the FEED reads is listed here too: that screen is a Zig view
    // now, so markup never binds its state (the welcome and Settings fragments
    // still bind theirs, and are still checked).
    pub const view_unbound = .{
        "notes",                 "notes_len",        "live_relays",            "offline_relays",   "draft_buffer",
        "stage",                 "login_buffer",     "logout_pending",         "reveal_nsec",      "proxy_buffer",
        "proxy_saved",           "feed_scroll",      "feed_limit",             "draft",            "draft_empty",
        "identity",              "has_notes",        "empty",                  "status",           "empty_text",
        "footer",                "note_list",        "expanded_note",          "composing",        "caught_up",
        "relay_health",          "relays_online",    "scope_voices",           "is_guest",         "show_guest_strip",
        "guest_strip_dismissed", "joining",          "pending_compose",        "naming",           "name_buffer",
        "name_draft",            "name_empty",       "toast_buf",              "toast_len",        "toast_until",
        "toast_text",            "backup_nudge",     "backup_nudge_dismissed", "bunker_mode",      "pending_like",
        "viewing_thread",        "reply_buffer",     "reply_draft",            "reply_empty",      "thread_root",
        "thread_notes",          "thread_notes_len", "thread_stack",           "thread_stack_len", "thread_loading",
        "thread_seq",            "thread_open_at",
    };

    /// The name beat's current text.
    pub fn name_draft(self: *const Model) []const u8 {
        return self.name_buffer.text();
    }
    /// Whether the name field is blank, which disables Save.
    pub fn name_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.name_buffer.text(), " \t\r\n").len == 0;
    }
    /// The live toast text, empty when none is showing.
    pub fn toast_text(self: *const Model) []const u8 {
        if (self.toast_until == 0) return "";
        return self.toast_buf[0..self.toast_len];
    }

    /// The composer's current text (what `text="{draft}"` binds).
    pub fn draft(self: *const Model) []const u8 {
        return self.draft_buffer.text();
    }
    /// Whether the draft is blank (only whitespace), which disables Post.
    pub fn draft_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.draft_buffer.text(), " \t\r\n").len == 0;
    }
    /// The reply composer's current text.
    pub fn reply_draft(self: *const Model) []const u8 {
        return self.reply_buffer.text();
    }
    /// Whether the reply is blank, which disables Reply.
    pub fn reply_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.reply_buffer.text(), " \t\r\n").len == 0;
    }
    /// The composer's "posting as" line: the identity's abbreviated npub, marked
    /// when signing is routed through an external signer, or a setup note while
    /// the key is still being prepared.
    pub fn identity(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        // A remote sign that never came back: the draft has been restored to the
        // composer, so say why rather than let it silently reappear.
        if (g_signer_kind == .remote and g_remote_sign_notice.load(.acquire))
            return "Your signer didn't respond. Draft restored, try again.";
        if (g_identity_npub_len == 0) return "Preparing your key…";
        // Show the user's own display name once their kind:0 is known, else npub.
        var who: []const u8 = g_identity_npub_buf[0..g_identity_npub_len];
        if (activePubkey()) |pk| {
            if (lookupProfile(pk)) |p| {
                if (p.name_len > 0) who = p.name();
            }
        }
        if (g_signer_kind == .remote) {
            // The connection's honest state, not just its happy path: reaching,
            // signing as (which key), or unreachable.
            return switch (g_remote_status.load(.acquire)) {
                1 => std.fmt.allocPrint(arena, "Reaching your signer · {s}", .{who}) catch who,
                2 => std.fmt.allocPrint(arena, "Signing via your signer · {s}", .{who}) catch who,
                3 => "Your signer is unreachable. Posts will not sign.",
                else => std.fmt.allocPrint(arena, "Your signer · {s}", .{who}) catch who,
            };
        }
        return std.fmt.allocPrint(arena, "Posting as {s}", .{who}) catch who;
    }

    /// The onboarding sign-in field text (what `text="{login_draft}"` binds).
    pub fn login_draft(self: *const Model) []const u8 {
        return self.login_buffer.text();
    }
    /// Whether the sign-in field is blank, which disables Continue.
    pub fn login_empty(self: *const Model) bool {
        return std.mem.trim(u8, self.login_buffer.text(), " \t\r\n").len == 0;
    }
    /// The status line under the sign-in field: a synchronous parse error, or
    /// the async bunker-connect state.
    pub fn login_status(self: *const Model) []const u8 {
        _ = self;
        switch (@as(LoginError, @enumFromInt(g_login_error.load(.acquire)))) {
            .format => return "Paste an nsec or a bunker link.",
            .bad_key => return "That doesn't look like a valid key.",
            .none => {},
        }
        return switch (g_remote_status.load(.acquire)) {
            1 => "Connecting to your signer…",
            3 => "Couldn't read that bunker link.",
            else => "",
        };
    }

    // -- Settings ------------------------------------------------------------

    /// The abbreviated npub of the signed-in identity (empty before sign-in).
    pub fn active_npub(self: *const Model) []const u8 {
        _ = self;
        return g_identity_npub_buf[0..g_identity_npub_len];
    }
    /// How the identity signs: a local key on this device, or a remote signer.
    pub fn identity_kind_label(self: *const Model) []const u8 {
        _ = self;
        return switch (g_signer_kind) {
            .local => "Local key",
            .remote => "Remote signer",
            .helper => "Signet",
        };
    }
    /// Whether the identity is a local key (so its secret can be backed up here).
    pub fn is_local_key(self: *const Model) bool {
        _ = self;
        return g_signer_kind == .local;
    }
    /// Whether the local secret key is hidden (the reveal toggle's off state).
    pub fn nsec_hidden(self: *const Model) bool {
        return !self.reveal_nsec;
    }
    /// Whether the secret key is currently revealed.
    pub fn nsec_shown(self: *const Model) bool {
        return self.reveal_nsec;
    }
    /// The revealed nsec (bech32 secret key), or empty when hidden or not local.
    pub fn revealed_nsec(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!self.reveal_nsec or g_signer_kind != .local) return "";
        const kp = g_identity_kp orelse return "";
        return nostr.nip19.encodeNsec(arena, kp.secret_key) catch "";
    }
    /// Whether the logout confirmation is not yet showing.
    pub fn logout_idle(self: *const Model) bool {
        return !self.logout_pending;
    }
    /// Whether the logout confirmation is showing.
    pub fn logout_confirming(self: *const Model) bool {
        return self.logout_pending;
    }
    /// The logout confirmation warning, sharper for a local key (it is deleted).
    pub fn logout_warning(self: *const Model) []const u8 {
        _ = self;
        return switch (g_signer_kind) {
            .local => "Your secret key will be removed from this device. Copy it first if you want to keep this identity.",
            .remote => "You'll be signed out and returned to the welcome screen. Your signer keeps your key.",
            .helper => "Your key will be removed from Signet on this device. Back it up first if you want to keep this identity.",
        };
    }
    /// The media-proxy field's text (what `text="{proxy_draft}"` binds).
    pub fn proxy_draft(self: *const Model) []const u8 {
        return self.proxy_buffer.text();
    }
    /// Confirmation under the media-proxy field.
    pub fn proxy_status(self: *const Model) []const u8 {
        if (!self.proxy_saved) return "";
        return if (g_media_proxy_len == 0) "Saved. Loading originals directly." else "Saved.";
    }
    /// What the previews switch is, in the terms that matter: not bandwidth.
    pub fn previews_explainer(self: *const Model) []const u8 {
        _ = self;
        return "Pictures, faces, link previews and NIP-05 checks are fetched from the hosts a note names. " ++
            "Off, none of that is asked for until you press a picture, and only your relays learn you are reading.";
    }
    pub fn previews_state(self: *const Model) []const u8 {
        _ = self;
        return if (g_media_previews) "On" else "Off. Press a picture to load that one.";
    }
    pub fn previews_action(self: *const Model) []const u8 {
        _ = self;
        return if (g_media_previews) "Turn off" else "Turn on";
    }
    /// How many notes are still waiting for their first relay. Read once per
    /// build, because the publisher writes the queue from its own thread and the
    /// view must see one answer for the whole frame.
    pub fn outbox_label(self: *const Model, arena: std.mem.Allocator) []const u8 {
        // A note that gave up is not "posting". Saying so would be the same lie
        // the queue was built to stop telling.
        if (self.outbox_pending == 0 and self.outbox_stuck > 0) {
            if (self.outbox_stuck == 1) return "1 note did not go out";
            return std.fmt.allocPrint(arena, "{d} notes did not go out", .{self.outbox_stuck}) catch "notes did not go out";
        }
        const n = self.outbox_pending;
        if (n == 1) return "posting 1 note…";
        return std.fmt.allocPrint(arena, "posting {d} notes…", .{n}) catch "posting…";
    }
    /// The app version line for the Settings footer.
    pub fn version_line(self: *const Model) []const u8 {
        _ = self;
        return "Plaza " ++ plaza_version;
    }

    /// The feed, iterated by `<for each="note_list">`, newest first.
    pub fn note_list(self: *const Model, arena: std.mem.Allocator) []const Note {
        _ = arena;
        return self.notes[0..self.notes_len];
    }
    pub fn has_notes(self: *const Model) bool {
        return self.notes_len > 0;
    }
    /// No notes yet, show the centered connecting/offline state (the message
    /// itself, `empty_text`, differentiates dialing from a dropped relay).
    pub fn empty(self: *const Model) bool {
        return self.notes_len == 0;
    }
    /// Header status line: how much of the relay pool is live.
    pub fn status(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.live_relays > 0)
            return std.fmt.allocPrint(arena, "Live · {d}/{d} relays", .{ self.live_relays, relays.len }) catch "Live";
        if (self.offline_relays >= relays.len) return "Offline, reconnecting…";
        return "Connecting…";
    }
    pub fn empty_text(self: *const Model) []const u8 {
        if (self.offline_relays >= relays.len) return "Can't reach any relay. Retrying…";
        return "Connecting to the relay pool…";
    }
    /// Status-bar summary.
    pub fn footer(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.notes_len == 0) return "";
        return std.fmt.allocPrint(arena, "{d} notes", .{self.notes_len}) catch "";
    }

    /// The status bar's left text, which doubles as the caught-up footer: there
    /// is no separate spinner, the feed renders from disk before the window
    /// finishes opening.
    pub fn caught_up(self: *const Model, arena: std.mem.Allocator) []const u8 {
        if (self.notes_len == 0) return "Starter pack";
        return std.fmt.allocPrint(arena, "Caught up · starter pack · {d} notes", .{self.notes_len}) catch "Starter pack";
    }

    /// The status bar's relay health, drawn after the online dot.
    pub fn relay_health(self: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}/{d} relays", .{ self.live_relays, relays.len }) catch "relays";
    }

    /// Whether at least one relay is connected (drives the status dot color).
    pub fn relays_online(self: *const Model) bool {
        return self.live_relays > 0;
    }

    /// Whether the reader is browsing without an identity. Reading never
    /// needs one; the gated verbs ask at first intent.
    pub fn is_guest(self: *const Model) bool {
        _ = self;
        return activePubkey() == null;
    }

    /// Whether the guest join strip is showing (guest, and not dismissed).
    pub fn show_guest_strip(self: *const Model) bool {
        return self.is_guest() and !self.guest_strip_dismissed;
    }

    /// The feed's scope line: how many hand-picked voices it is scoped to.
    pub fn scope_voices(self: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "{d} voices · hand-picked", .{starter_pack.len}) catch "hand-picked";
    }

    /// The note with this id, if it is still in the feed or the open thread. A
    /// thread's root and replies are not in the feed window but are still
    /// pressable (like, image, open-as-thread), so they resolve here too.
    pub fn noteById(self: *const Model, note_id: i64) ?*const Note {
        for (self.notes[0..self.notes_len]) |*note| {
            if (note.id == note_id) return note;
        }
        if (self.viewing_thread != 0) {
            if (self.thread_root.id == note_id) return &self.thread_root;
            for (self.thread_notes[0..self.thread_notes_len]) |*note| {
                if (note.id == note_id) return note;
            }
        }
        return null;
    }

    /// Which level of the thread stack is on screen. Every per-level table is
    /// indexed by this, and it is clamped because the stack saturates at
    /// `thread_depth_max` by replacing its top rather than growing.
    pub fn currentLevel(self: *const Model) usize {
        return @min(self.thread_stack_len, thread_depth_max);
    }

    /// Rebuilds the open thread's replies from the store: every kind:1 that
    /// e-tags the root, oldest first, into the `thread_notes` cache. Local-first,
    /// the same path the feed uses; cheap enough to run each tick so
    /// late-arriving replies appear and relative times stay fresh.
    fn refreshThreadNotes(self: *Model, now_s: i64) void {
        if (self.viewing_thread == 0) return;
        const store = g_store orelse return;
        // The whole subtree, not just the direct children: the closure walk is
        // what keeps a SUB-thread's deep replies visible (they tag the true
        // root and their direct parent, never a mid-thread note).
        var ids: [thread_reply_cap][32]u8 = undefined;
        const id_count = collectThreadIds(store, self.thread_root.event_id, &ids);

        var n: usize = 0;
        for (ids[0..id_count]) |id| {
            if (n >= self.thread_notes.len) break;
            var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
            defer se.deinit();
            self.thread_notes[n] = noteFrom(se.event, now_s);
            // Queue the replier's profile so a name, avatar, and handle resolve
            // for a reply from someone outside the follow set.
            wantProfile(se.event.pubkey);
            n += 1;
        }
        // Whether this thread's own fetch has asked every relay and come back, or
        // given up waiting on one that never sends its EOSE. Until then the
        // replies are still streaming in and belong to one batch.
        const done = g_thread_done_seq.load(.acquire) == self.thread_seq;
        const timed_out = now_s - self.thread_open_at > thread_loading_grace_s;
        stampArrival(arrivalTableFor(self.thread_stack_len, self.thread_root.event_id), self.thread_notes[0..n], done or timed_out);
        // In reading order, so seat each reply under the note it answers.
        arrangeThread(self.thread_notes[0..n], self.thread_root.event_id);
        self.thread_notes_len = n;
        // Stop the loading skeletons once replies are in hand, OR once the fetch
        // is done or timed out. Otherwise skeletons would stall forever under a
        // note that simply has no replies.
        if (self.thread_loading and (n > 0 or done or timed_out)) self.thread_loading = false;
    }

    /// The reply count for the thread breadcrumb: the crowd count the feed's
    /// engagement subscription already knows (so it reads right the instant a
    /// thread opens, before the replies are fetched), or the fetched count once
    /// that is higher.
    fn threadReplyCount(self: *const Model) usize {
        const crowd: usize = engagementFor(self.thread_root.id).replies;
        return @max(crowd, self.thread_notes_len);
    }

    /// The span of notes at or near the viewport, which is what gets pictures.
    /// Card heights vary, so this estimates from the average (total content over
    /// note count) and pads generously; being a row or two wide only costs a
    /// prefetch. Before the first scroll event it reports the top of the feed.
    pub fn visibleRange(self: *const Model) struct { first: usize, last: usize } {
        if (self.notes_len == 0) return .{ .first = 0, .last = 0 };
        // The windowed list reports the exact rows it put on screen, so this is
        // no longer an estimate. Before the first build it reports the top.
        const last_row = self.notes_len - 1;
        if (g_visible_last == 0 and g_visible_first == 0) {
            return .{ .first = 0, .last = @min(last_row, max_media_images - 1) };
        }
        return .{ .first = @min(g_visible_first, last_row), .last = @min(g_visible_last, last_row) };
    }

    /// Reconciles the feed with the store. Updates the connection line every
    /// tick; re-queries and rebuilds the note cards only when the store's event
    /// count changed since the last rebuild; and re-computes relative times for
    /// the notes on screen. `now_s` is the current wall-clock second.
    fn refresh(self: *Model, now_s: i64) void {
        var live: usize = 0;
        var offline: usize = 0;
        for (&g_relay_status) |*s| {
            switch (@as(Conn, @enumFromInt(s.load(.acquire)))) {
                .connected => live += 1,
                .offline => offline += 1,
                .connecting => {},
            }
        }
        self.live_relays = live;
        self.offline_relays = offline;

        const store = g_store orelse return;

        const count = store.eventCount() catch return;
        if (count != g_last_count) {
            g_last_count = count;
            // Profiles first, so a note's mentions resolve to names as it builds.
            refreshProfiles(store);
            rebuildNotes(self, store, now_s);
            // A grown store may hold quoted events the feed references now.
            refreshQuotes(store);
        }
        for (self.notes[0..self.notes_len]) |*note| note.setTime(now_s);
    }

    fn rebuildNotes(self: *Model, store: *nostr.store.Store, now_s: i64) void {
        const kinds = [_]u16{1};
        // Scope the feed to the follow set (the starter pack) plus the user's own
        // notes, so it reads as a real follow feed, not a firehose. Filtering
        // here (not just at the subscription) also hides notes an earlier,
        // unscoped run may have left in the store.
        var authors: [starter_pack.len + 1][32]u8 = starter_pack ++ [_][32]u8{undefined};
        var authors_len: usize = starter_pack.len;
        if (activePubkey()) |pk| {
            authors[authors_len] = pk;
            authors_len += 1;
        }
        // Only as much as the reader has paged into, so the rebuild cost stays
        // flat until they actually ask for more.
        const limit = @min(self.feed_limit, feed_capacity);
        var result = store.query(std.heap.page_allocator, .{ .authors = authors[0..authors_len], .kinds = &kinds, .limit = @intCast(limit) }) catch return;
        defer result.deinit();

        // The store's count moves on every kind of ingest (profiles included),
        // and the pool streams all day, so this runs about once a second. The
        // notes themselves rarely change: reuse the already-parsed card whenever
        // the event is one we hold, and parse only what is genuinely new.
        // Mention labels are baked into content at parse time, so a new display
        // name (the generation) forces one full parse pass to refresh them.
        const reuse_ok = g_names_generation == g_notes_names_generation;
        g_notes_names_generation = g_names_generation;

        // Nothing new at all: the usual tick, when the count moved for some
        // other kind of event. Keep every card exactly as it is.
        if (reuse_ok and result.events.len == self.notes_len) {
            var same = true;
            for (result.events, 0..) |ev, i| {
                if (noteIdOf(ev) != self.notes[i].id) {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }

        // The old cards, so new positions can take them over by id.
        const old = &g_notes_scratch;
        const old_len = self.notes_len;
        @memcpy(old[0..old_len], self.notes[0..old_len]);

        var n: usize = 0;
        for (result.events) |ev| {
            if (n >= limit) break;
            const id = noteIdOf(ev);
            self.notes[n] = blk: {
                if (reuse_ok) {
                    for (old[0..old_len]) |*prev| {
                        if (prev.id == id) break :blk prev.*;
                    }
                }
                break :blk noteFrom(ev, now_s);
            };
            n += 1;
        }
        self.notes_len = n;
    }
};

/// Adopts `secret` as the active local identity. For tests: the feed scopes
/// its queries to the follow set plus the signed-in user, so a test that
/// stores its own events needs to BE somebody.
pub fn setIdentityForTest(secret: [32]u8) void {
    var signer = nostr.keys.Signer.init();
    const kp = signer.keyPairFromSecretKey(secret) catch {
        signer.deinit();
        return;
    };
    g_signer_kind = .local;
    setIdentity(signer, kp);
}

/// Clears the active identity again. For tests.
pub fn clearIdentityForTest() void {
    if (g_identity_signer) |*sgn| sgn.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_identity_npub_len = 0;
    g_signer_kind = .local;
}

/// Reconciles profiles and notes against `store` directly, bypassing the
/// count guard. For tests, which drive the store themselves.
pub fn reconcileForTest(model: *Model, store: *nostr.store.Store, now_s: i64) void {
    refreshProfiles(store);
    model.rebuildNotes(store, now_s);
}

/// The feed key derived from an event id: the first eight bytes, sign bit
/// masked so the markup engine's i64 key round-trip never overflows.
pub fn noteIdOf(ev: nostr.event.Event) i64 {
    return @intCast(std.mem.readInt(u64, ev.id[0..8], .big) & std.math.maxInt(i64));
}

// The previous feed, kept across one rebuild so unchanged notes carry over
// without being re-parsed. Static rather than stack: three hundred cards of
// fixed buffers are far too big for a frame's stack.
var g_notes_scratch: [feed_capacity]Note = [_]Note{.{}} ** feed_capacity;
// The names generation the current cards were parsed under (see
// `g_names_generation`).
var g_notes_names_generation: u64 = 0;

/// Reads kind:0 metadata for the feed's authors from the store and parses each
/// into the profile cache. The store keeps only the newest kind:0 per author, so
/// this always reflects the current metadata.
fn refreshProfiles(store: *nostr.store.Store) void {
    const kinds = [_]u16{0};
    var authors: [starter_pack.len + 1 + wanted_profiles_cap][32]u8 = undefined;
    var authors_len: usize = 0;
    for (starter_pack) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    if (activePubkey()) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    // Anyone a note mentioned, so their name resolves once it arrives.
    for (&g_wanted) |*w| {
        if (!w.used) continue;
        authors[authors_len] = w.pubkey;
        authors_len += 1;
    }
    var result = store.query(std.heap.page_allocator, .{ .authors = authors[0..authors_len], .kinds = &kinds, .limit = profile_cap + wanted_profiles_cap }) catch return;
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
fn markAvatarWanted(pubkey: [32]u8) void {
    if (upsertProfile(pubkey)) |p| p.avatar_clock = g_avatar_clock;
}

/// Lends the `max_avatar_images` registry ids to the authors on screen right
/// now (the feed's visible window, or the open thread), reclaiming ids from
/// authors who scrolled away. There are far more cached authors than ids, so
/// without this only the first handful ever seen could hold a face and a
/// thread of strangers showed initials for everyone. Runs each tick before
/// `scanAvatarFetches`, which then fetches the faces for whoever just gained an
/// id. `fx` is needed to free a reclaimed id's registered image.
fn assignAvatarSlots(fx: *Effects, model: *const Model) void {
    g_avatar_clock += 1;

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
    if (model.viewing_thread != 0) {
        // A thread occludes the feed, so its authors own the ids while it is up.
        push(&onscreen, &n, model.thread_root.pubkey);
        for (model.thread_notes[0..model.thread_notes_len]) |*note| push(&onscreen, &n, note.pubkey);
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

/// Assigns `p` a free registry id, or the id of the author least-recently on
/// screen (never one mid-fetch, never one on screen this pass, so a just-lent id
/// is safe). A no-op when every id is held by an on-screen author (that author
/// keeps initials this frame). A reclaimed id's old image is unregistered and its
/// former owner reset to reload from cache when it returns.
fn claimAvatarSlot(fx: *Effects, p: *Profile) void {
    var held = [_]bool{false} ** (max_avatar_images + 1);
    for (&g_profiles) |*q| {
        if (q.used and q.image_id >= 1 and q.image_id <= max_avatar_images) held[@intCast(q.image_id)] = true;
    }
    var id: usize = 1;
    while (id <= max_avatar_images) : (id += 1) {
        if (!held[id]) {
            p.image_id = @intCast(id);
            return;
        }
    }
    var victim: ?*Profile = null;
    for (&g_profiles) |*q| {
        if (!q.used or q.image_id == 0) continue;
        if (q.avatar_clock == g_avatar_clock or q.avatar_state == .fetching) continue;
        if (victim == null or q.avatar_clock < victim.?.avatar_clock) victim = q;
    }
    const v = victim orelse return;
    const reclaimed = v.image_id;
    _ = fx.unregisterImage(reclaimed);
    v.image_id = 0;
    v.avatar_state = .idle;
    p.image_id = reclaimed;
}

/// Fires avatar fetches for cached profiles that have a picture and an image
/// slot but no avatar yet, a few per tick to stay well inside the effect budget.
/// The response lands on `avatar_fetched`.
fn scanAvatarFetches(fx: *Effects) void {
    // A face is something the note points at, like its picture.
    if (!g_media_previews) return;
    const per_tick = 8;
    var fired: usize = 0;
    for (&g_profiles, 0..) |*p, i| {
        if (!p.used or p.avatar_state != .idle or p.picture_len == 0 or p.image_id == 0) continue;

        var url_buf: [1024]u8 = undefined;
        const url = mediaUrl(&url_buf, p.picture(), avatar_target_px, .square);
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
        fx.fetch(.{
            .key = avatar_fetch_key_base + @as(u64, @intCast(i)),
            .url = p.url(),
            .on_response = Effects.responseMsg(.avatar_fetched),
        });
        fired += 1;
    }
}

/// Handles an avatar fetch response: registers the decoded image on success, or
/// retries a slot-starved rejection and gives up (initials) on anything else.
fn handleAvatarFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key < avatar_fetch_key_base) return;
    const slot = response.key - avatar_fetch_key_base;
    if (slot >= g_profiles.len) return;
    const p = &g_profiles[@intCast(slot)];
    if (!p.used) return;

    // A rejection means every effect slot was busy: try again next tick.
    if (response.outcome == .rejected) {
        p.avatar_state = .idle;
        return;
    }
    // Anything but a clean, whole, OK image body falls back to initials.
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0 or response.body.len > max_image_bytes) {
        p.avatar_state = .failed;
        return;
    }
    // Decode into this profile's fixed image id, downscaling if the platform
    // decoder will not take it as-is. Only a genuinely undecodable body falls
    // back to initials now.
    if (decodeAndRegister(fx, p.image_id, response.body, avatar_target_px)) |_| {
        p.avatar_state = .loaded;
        storeCachedImage(p.url(), response.body);
    } else {
        p.avatar_state = .failed;
    }
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
fn scanNip05Fetches(fx: *Effects) void {
    // Verifying a NIP-05 means asking a domain a stranger wrote whether it knows
    // this key, from the reader's own address. That is the same disclosure the
    // switch exists to stop, so it stops here too, and unverified names simply
    // show without a check.
    if (!g_media_previews) return;
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

/// True when the well-known JSON maps the identifier's name to `pubkey`. This is
/// the whole trust test: a check is drawn on this and nothing weaker.
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
fn handleNip05Fetched(response: native_sdk.EffectResponse) void {
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

// --------------------------------------------------------------- image decode
//
// The canvas image registry decodes through the platform codec and refuses
// anything over 512x512, with no downscaler of its own. Most real avatars and
// nearly every feed photo are larger than that, so Plaza decodes and resizes
// them itself: the platform decoder is tried first (it knows every format the
// OS does, WebP and HEIC included), and stb takes over when it refuses.

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_load_gif_from_memory(buffer: [*]const u8, len: c_int, delays: *?[*]c_int, x: *c_int, y: *c_int, z: *c_int, comp: ?*c_int, req_comp: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbir_resize_uint8_linear(input_pixels: [*]const u8, input_w: c_int, input_h: c_int, input_stride_in_bytes: c_int, output_pixels: [*]u8, output_w: c_int, output_h: c_int, output_stride_in_bytes: c_int, pixel_layout: c_int) ?[*]u8;

/// `STBIR_RGBA`: four channels, alpha not premultiplied, which is what both stb
/// hands back and the registry wants.
const stbir_rgba: c_int = 4;

// The image cache: every image Plaza fetches is written to `$HOME/.plaza/media`
// under a hash of the URL it was fetched from (which encodes the requested
// size), and read back before the network is touched. This is what makes
// avatars and pictures local-first like the notes themselves: on every launch
// after the first they are on screen with the feed, not seconds later.

/// The cache file name for `url`: its SHA-256, hex encoded.
fn cacheName(out: *[64]u8, url: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hexdigits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hexdigits[b >> 4];
        out[i * 2 + 1] = hexdigits[b & 0x0f];
    }
    return out[0..];
}

/// Opens (creating if needed) `$HOME/.plaza/media`.
fn mediaCacheDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza/media", .{home});
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

/// Registers `url`'s image from the on-disk cache, if it is there. Reading a
/// handful of small files is fast enough to do inline, and it is what lets the
/// first painted frame already carry avatars.
fn loadCachedImage(fx: *Effects, id: u64, url: []const u8, max_dim: u32) ?DecodedSize {
    const io = g_io orelse return null;
    const environ = g_environ orelse return null;
    var dir = mediaCacheDir(io, environ) catch return null;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    const gpa = std.heap.page_allocator;
    const bytes = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(max_image_bytes)) catch return null;
    defer gpa.free(bytes);
    return decodeAndRegister(fx, id, bytes, max_dim);
}

/// Writes a freshly fetched image into the cache. Best-effort: a failure here
/// only costs a re-download next launch.
fn storeCachedImage(url: []const u8, bytes: []const u8) void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = mediaCacheDir(io, environ) catch return;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, url);
    dir.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
}

/// The pixel size an image ended up registered at, so the view can lay it out
/// at its real aspect instead of stretching it into whatever box it is given.
const DecodedSize = struct { width: usize, height: usize };

/// Decodes `bytes` and registers the pixels under `id`, downscaling so the long
/// edge is at most `max_dim`. Returns the registered size, or null on failure.
fn decodeAndRegister(fx: *Effects, id: u64, bytes: []const u8, max_dim: u32) ?DecodedSize {
    // Fast path: let the platform decode and register directly. This succeeds
    // whenever the image already fits the registry's budget.
    if (fx.registerImageBytes(id, bytes)) |registered| {
        return .{ .width = registered.width, .height = registered.height };
    } else |_| {}

    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return null;
    defer stbi_image_free(pixels);
    if (w <= 0 or h <= 0) return null;

    const src_w: usize = @intCast(w);
    const src_h: usize = @intCast(h);
    const longest = @max(src_w, src_h);
    if (longest <= max_dim) {
        // The platform refused it for some other reason; the decoded pixels
        // still fit, so register them as they are.
        fx.registerImage(id, src_w, src_h, pixels[0 .. src_w * src_h * 4]) catch return null;
        return .{ .width = src_w, .height = src_h };
    }

    const scale = @as(f64, @floatFromInt(max_dim)) / @as(f64, @floatFromInt(longest));
    const dst_w: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(src_w)) * scale)));
    const dst_h: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(src_h)) * scale)));

    const gpa = std.heap.page_allocator;
    const out = gpa.alloc(u8, dst_w * dst_h * 4) catch return null;
    defer gpa.free(out);
    if (stbir_resize_uint8_linear(pixels, w, h, 0, out.ptr, @intCast(dst_w), @intCast(dst_h), 0, stbir_rgba) == null) return null;
    fx.registerImage(id, dst_w, dst_h, out) catch return null;
    return .{ .width = dst_w, .height = dst_h };
}

// ---------------------------------------------------------------- feed media
//
// Feed images take the image ids the avatars do not, through a small LRU keyed
// by note. Only the top of the feed loads for now: that is what the budget
// holds and what is on screen at rest. Windowed visibility (load exactly what
// is in view, evict what leaves) arrives with the virtual list.

const MediaSlot = struct {
    used: bool = false,
    note_id: i64 = 0,
    image_id: u64 = 0,
    state: enum { idle, fetching, loaded, failed } = .idle,
    /// Tick counter at the last time this note was still wanted, for eviction.
    last_used: u64 = 0,
    /// The registered pixel size, so the card can lay the picture out at its
    /// own aspect rather than stretching it.
    width: usize = 0,
    height: usize = 0,
    /// The resolved URL this image is fetched from, which is also its cache key.
    url_buf: [1024]u8 = [_]u8{0} ** 1024,
    url_len: u16 = 0,
    /// Every frame of an animated GIF, decoded once and owned by stb (freed on
    /// eviction). Null for a still picture.
    frames: ?[*]u8 = null,
    frame_count: u16 = 0,
    frame_index: u16 = 0,
    /// Milliseconds this GIF holds each frame, and how much of that has elapsed.
    frame_delay_ms: u32 = 100,
    elapsed_ms: u32 = 0,

    fn url(self: *const MediaSlot) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    fn animated(self: *const MediaSlot) bool {
        return self.frames != null and self.frame_count > 1;
    }
    /// Releases the decoded frames, if any. Called before a slot is reused.
    fn releaseFrames(self: *MediaSlot) void {
        if (self.frames) |px| stbi_image_free(px);
        self.frames = null;
        self.frame_count = 0;
        self.frame_index = 0;
    }
};

var g_media = [_]MediaSlot{.{}} ** max_media_images;
var g_media_clock: u64 = 0;

// The rows the windowed list last put on screen. Written by the view (which is
// where the runtime resolves the window) and read by the fetch pass in
// `update`, so the image budget follows the reader exactly.
var g_visible_first: usize = 0;
var g_visible_last: usize = 0;

// What shape each note's picture turned out to be, remembered per note id and
// OUTLIVING both the media slot and the note itself. A slot is evicted as soon
// as the note scrolls out of the window; without this the card would forget how
// tall its picture was, shrink, and shift the feed under the reader, then shift
// it back on the way up. Notes whose `imeta` declared a size never need it.
const aspect_memory_cap = 128;
const AspectEntry = struct { note_id: i64 = 0, aspect: f32 = 0 };
var g_aspects = [_]AspectEntry{.{}} ** aspect_memory_cap;
var g_aspect_next: usize = 0;

/// Records the shape of `note_id`'s picture.
fn rememberAspect(note_id: i64, width: usize, height: usize) void {
    if (width == 0 or height == 0) return;
    const aspect = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(width));
    for (&g_aspects) |*entry| {
        if (entry.note_id == note_id) {
            entry.aspect = aspect;
            return;
        }
    }
    g_aspects[g_aspect_next] = .{ .note_id = note_id, .aspect = aspect };
    g_aspect_next = (g_aspect_next + 1) % aspect_memory_cap;
}

/// The remembered shape of `note_id`'s picture, if it has been seen.
fn recalledAspect(note_id: i64) ?f32 {
    for (&g_aspects) |entry| {
        if (entry.note_id == note_id and entry.aspect > 0) return entry.aspect;
    }
    return null;
}

/// Clears the media cache. For tests, which share the process globals.
pub fn resetMediaForTest() void {
    g_media = [_]MediaSlot{.{}} ** max_media_images;
    g_media_clock = 0;
}

/// The slot holding `note_id`'s image, if any.
fn mediaSlotFor(note_id: i64) ?*MediaSlot {
    for (&g_media) |*m| {
        if (m.used and m.note_id == note_id) return m;
    }
    return null;
}

/// The slot for `note_id`, claiming a free one or evicting the least recently
/// wanted. Never evicts a slot whose note is still on screen (touched this
/// pass), and never one with a fetch in flight: when more pictures are visible
/// than there are slots, the extras hold their reserved space rather than
/// stealing each other's slot back and forth, which decoded images on the UI
/// thread every pass and made a tall window feel heavy.
pub fn claimMediaSlotForTest(fx: *Effects, note_id: i64) ?*MediaSlot {
    return claimMediaSlot(fx, note_id);
}

pub fn touchMediaClockForTest() u64 {
    g_media_clock += 1;
    return g_media_clock;
}

fn claimMediaSlot(fx: *Effects, note_id: i64) ?*MediaSlot {
    if (mediaSlotFor(note_id)) |m| return m;
    for (&g_media, 0..) |*m, i| {
        if (!m.used) {
            m.* = .{ .used = true, .note_id = note_id, .image_id = media_image_id_base + i };
            return m;
        }
    }
    var victim: ?*MediaSlot = null;
    for (&g_media) |*m| {
        if (m.state == .fetching) continue;
        if (m.last_used == g_media_clock) continue; // still wanted on screen
        if (victim == null or m.last_used < victim.?.last_used) victim = m;
    }
    const v = victim orelse return null;
    const id = v.image_id;
    // Free the registry slot and any decoded frames before reusing the id.
    _ = fx.unregisterImage(id);
    v.releaseFrames();
    v.* = .{ .used = true, .note_id = note_id, .image_id = id };
    return v;
}

/// Decodes every frame of an animated GIF into `slot` and registers the first,
/// so the shared animation timer can cycle it. Returns false for a still image
/// (including a single-frame GIF), leaving the normal still path to handle it.
fn loadAnimatedGif(fx: *Effects, slot: *MediaSlot, bytes: []const u8) bool {
    if (bytes.len < 3 or !std.mem.eql(u8, bytes[0..3], "GIF")) return false;

    var delays: ?[*]c_int = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var count: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_gif_from_memory(bytes.ptr, @intCast(bytes.len), &delays, &w, &h, &count, &comp, 4) orelse return false;
    if (count <= 1 or w <= 0 or h <= 0) {
        stbi_image_free(pixels);
        return false;
    }

    const frame_w: usize = @intCast(w);
    const frame_h: usize = @intCast(h);
    const frame_bytes = frame_w * frame_h * 4;
    const frames: usize = @intCast(count);
    // stb decodes every frame up front, so a long or large GIF is the real
    // memory hazard rather than the per-frame cost. Refuse the extremes and let
    // the caller fall back to a still first frame.
    if (frame_bytes > max_registered_image_bytes or frames > max_gif_frames or frame_bytes * frames > max_gif_total_bytes) {
        stbi_image_free(pixels);
        return false;
    }

    fx.registerImage(slot.image_id, frame_w, frame_h, pixels[0..frame_bytes]) catch {
        stbi_image_free(pixels);
        return false;
    };

    slot.releaseFrames();
    slot.frames = pixels;
    slot.frame_count = @intCast(frames);
    slot.frame_index = 0;
    slot.elapsed_ms = 0;
    // GIF delays are centiseconds x10; anything implausibly fast gets the
    // browsers' customary floor.
    slot.frame_delay_ms = if (delays) |d| (if (d[0] >= 20) @intCast(d[0]) else 100) else 100;
    slot.width = frame_w;
    slot.height = frame_h;
    slot.state = .loaded;
    rememberAspect(slot.note_id, frame_w, frame_h);
    return true;
}

/// Registers a feed picture from the on-disk cache, animating it if it is a GIF.
/// Returns whether the slot is now loaded.
fn loadCachedMedia(fx: *Effects, slot: *MediaSlot, gif: bool) bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;
    var dir = mediaCacheDir(io, environ) catch return false;
    defer dir.close(io);

    var name_buf: [64]u8 = undefined;
    const name = cacheName(&name_buf, slot.url());
    const gpa = std.heap.page_allocator;
    const bytes = dir.readFileAlloc(io, name, gpa, std.Io.Limit.limited(max_image_bytes)) catch return false;
    defer gpa.free(bytes);

    if (gif and loadAnimatedGif(fx, slot, bytes)) return true;
    if (decodeAndRegister(fx, slot.image_id, bytes, media_target_px)) |size| {
        slot.state = .loaded;
        slot.width = size.width;
        slot.height = size.height;
        rememberAspect(slot.note_id, size.width, size.height);
        return true;
    }
    return false;
}

/// Advances the animated pictures currently in view, one shared timer for all of
/// them (a timer each would exhaust the 16-slot timer table). Only a couple play
/// at once: the rest hold their first frame until they scroll into that budget.
fn advanceAnimations(fx: *Effects, model: *const Model) void {
    const window = model.visibleRange();
    var playing: usize = 0;
    for (&g_media) |*slot| {
        if (!slot.used or !slot.animated() or slot.state != .loaded) continue;
        // In view? The note has to still be one of the ones on screen.
        var visible = false;
        var index = window.first;
        while (index <= window.last and index < model.notes_len) : (index += 1) {
            if (model.notes[index].id == slot.note_id) {
                visible = true;
                break;
            }
        }
        if (!visible) continue;
        if (playing >= max_playing_gifs) break;
        playing += 1;

        slot.elapsed_ms += animation_interval_ms;
        if (slot.elapsed_ms < slot.frame_delay_ms) continue;
        slot.elapsed_ms = 0;
        slot.frame_index = (slot.frame_index + 1) % slot.frame_count;

        const frames = slot.frames orelse continue;
        const frame_bytes = slot.width * slot.height * 4;
        const offset = @as(usize, slot.frame_index) * frame_bytes;
        // Re-registering the same id swaps the pixels everywhere it is drawn.
        fx.registerImage(slot.image_id, slot.width, slot.height, frames[offset..][0..frame_bytes]) catch {};
    }
}

/// Loads the pictures for the notes around the viewport: the cached ones
/// straight from disk, the rest over the network a few per tick. Notes outside
/// the window keep their slot only until something on screen needs it. While a
/// thread is open the feed under it is hidden, so the budget goes to the thread's
/// pictures instead (the feed's reload from the disk cache when it returns).
fn scanMediaFetches(fx: *Effects, model: *const Model) void {
    const per_tick = 6;
    var fired: usize = 0;
    g_media_clock += 1;

    if (model.viewing_thread != 0) {
        // Mark, then fetch: marking every thread picture wanted first means the
        // claim pass can only evict the (now hidden) feed's slots, never a
        // thread picture needed later in this same pass.
        markMediaWanted(model.thread_root.id);
        for (model.thread_notes[0..model.thread_notes_len]) |*note| markMediaWanted(note.id);
        fireMedia(fx, &model.thread_root, &fired, per_tick);
        for (model.thread_notes[0..model.thread_notes_len]) |*note| fireMedia(fx, note, &fired, per_tick);
        return;
    }

    const window = model.visibleRange();

    // First mark every slot whose note is on screen as wanted, so the claim
    // pass below can only ever evict pictures that have scrolled away. Without
    // this, a viewport showing more pictures than there are slots would evict
    // a slot needed later in this very pass, endlessly.
    var touch = window.first;
    while (touch <= window.last and touch < model.notes_len) : (touch += 1) {
        markMediaWanted(model.notes[touch].id);
    }

    var index = window.first;
    while (index <= window.last and index < model.notes_len) : (index += 1) {
        fireMedia(fx, &model.notes[index], &fired, per_tick);
    }
}

/// Marks the picture slot for `note_id` wanted this pass (if it has one), so the
/// claim pass does not evict a picture still on screen.
fn markMediaWanted(note_id: i64) void {
    if (mediaSlotFor(note_id)) |m| m.last_used = g_media_clock;
}

/// Loads one note's picture: claims a slot, serves it from the disk cache, or
/// fetches it over the network (up to `per_tick` fetches a pass). A note with no
/// picture, or one whose slot is already loading or done, is a no-op.
fn fireMedia(fx: *Effects, note: *const Note, fired: *usize, per_tick: usize) void {
    if (!note.hasImage()) return;
    // With previews off, nothing leaves the machine until the reader asks for
    // this one picture. That is the point of the setting: not bandwidth, but
    // that reading a feed should not tell every host in it that you did.
    if (!g_media_previews and !isMediaAsked(note.id)) return;
    const slot = claimMediaSlot(fx, note.id) orelse return;
    slot.last_used = g_media_clock;
    if (slot.state != .idle) return;

    var url_buf: [1024]u8 = undefined;
    const gif = isGifUrl(note.imageUrl());
    const url = if (gif)
        mediaUrl(&url_buf, note.imageUrl(), gif_target_px, .animation)
    else
        mediaUrl(&url_buf, note.imageUrl(), media_target_px, .inside);
    const n = @min(url.len, slot.url_buf.len);
    @memcpy(slot.url_buf[0..n], url[0..n]);
    slot.url_len = @intCast(n);

    // Local-first: a picture we already have appears with the note, with no
    // network round-trip at all.
    if (loadCachedMedia(fx, slot, gif)) return;
    if (fired.* >= per_tick) return;
    slot.state = .fetching;
    fx.fetch(.{
        .key = media_fetch_key_base + (slot.image_id - media_image_id_base),
        .url = slot.url(),
        .on_response = Effects.responseMsg(.media_fetched),
    });
    fired.* += 1;
}

/// Handles a feed-image fetch response, mirroring the avatar path.
fn handleMediaFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key < media_fetch_key_base) return;
    const index = response.key - media_fetch_key_base;
    if (index >= g_media.len) return;
    const slot = &g_media[@intCast(index)];
    if (!slot.used) return;

    if (response.outcome == .rejected) {
        slot.state = .idle;
        return;
    }
    if (response.outcome != .ok or response.status != 200 or response.truncated or response.body.len == 0 or response.body.len > max_image_bytes) {
        slot.state = .failed;
        return;
    }
    // An animated GIF keeps all its frames; anything else (including a GIF with
    // only one frame) takes the still path.
    if (loadAnimatedGif(fx, slot, response.body)) {
        storeCachedImage(slot.url(), response.body);
        return;
    }
    if (decodeAndRegister(fx, slot.image_id, response.body, media_target_px)) |size| {
        slot.state = .loaded;
        slot.width = size.width;
        slot.height = size.height;
        rememberAspect(slot.note_id, size.width, size.height);
        // Keep it for next launch: the feed should come back with its pictures.
        storeCachedImage(slot.url(), response.body);
    } else {
        slot.state = .failed;
    }
}

// A pressed link is handed to the OS opener. The URL comes from note content,
// which is untrusted, so it is validated before it ever becomes an argument: it
// must be a plain http(s) URL with no whitespace or control bytes. There is no
// shell involved (argv is passed as a vector), and a leading scheme means the
// opener can never read it as a flag or a local path.
var g_open_url_buf: [1024]u8 = undefined;

/// Whether `url` is safe to hand to the system opener.
pub fn isSafeExternalUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    if (url.len > g_open_url_buf.len) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// Opens `url` in the user's browser, if it passes validation.
fn openExternally(fx: *Effects, url: []const u8) void {
    if (!isSafeExternalUrl(url)) return;
    // The link slice lives in the view arena, so copy it before the effect runs.
    @memcpy(g_open_url_buf[0..url.len], url);
    const owned = g_open_url_buf[0..url.len];
    fx.spawn(.{ .key = open_url_key, .argv = &.{ "/usr/bin/open", owned }, .output = .collect });
}

/// Lets everything that failed to load try again, after the media proxy changed.
fn retryFailedImages() void {
    for (&g_profiles) |*p| {
        if (p.used and p.avatar_state == .failed) p.avatar_state = .idle;
    }
    for (&g_media) |*m| {
        if (m.used and m.state == .failed) m.state = .idle;
    }
}

/// Builds a `Note` view-model from a stored event.
pub fn noteFrom(ev: nostr.event.Event, now_s: i64) Note {
    var note = Note{
        .created_at = ev.created_at,
        .pubkey = ev.pubkey,
        .id = noteIdOf(ev),
        .event_id = ev.id,
    };

    // Avatar initials fallback: the first pubkey byte as two hex digits, stable
    // and distinct per author, shown until an avatar image loads.
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[ev.pubkey[0] >> 4], hexdigits[ev.pubkey[0] & 0x0f] };

    setAuthor(&note, ev.pubkey);

    // An image link becomes a picture, so lift it out of the text and omit it
    // from the rendered content rather than showing a bare URL beside it.
    var image_url: []const u8 = "";
    if (firstImageUrl(ev.content)) |url| {
        if (url.len <= note.image_url_buf.len) {
            @memcpy(note.image_url_buf[0..url.len], url);
            note.image_url_len = @intCast(url.len);
            image_url = note.imageUrl();
            const meta = imetaFor(ev.tags, url);
            note.image_aspect = meta.aspect();
            note.image_w = meta.width;
            note.image_h = meta.height;
            note.image_bytes = meta.size;
            const blur_len = @min(meta.blurhash.len, note.image_blur_buf.len);
            @memcpy(note.image_blur_buf[0..blur_len], meta.blurhash[0..blur_len]);
            note.image_blur_len = @intCast(blur_len);
            note.image_has_alt = meta.alt.len > 0;
        }
    }

    // Content: `nostr:` mentions rewritten to @name (or a short @npub), copied
    // whole-codepoint so a split multi-byte sequence never reaches the shaper.
    note.content_len = @intCast(renderContent(&note.content_buf, ev.content, image_url));

    // The first plain link, for the preview card. Read from the ORIGINAL content:
    // the rendered copy has mentions rewritten and may be capped.
    if (firstLinkUrl(ev.content, image_url)) |link| {
        if (link.len <= note.link_url_buf.len) {
            @memcpy(note.link_url_buf[0..link.len], link);
            note.link_url_len = @intCast(link.len);
        }
    }

    // The first quoted event (nevent/note), decoded once into a byte span the
    // body splits on, and queued for resolving.
    findQuoteRef(&note);
    if (note.quote.kind == .event) wantQuote(note.quote.id);

    // Which note this one answers, for thread nesting.
    if (nip10Parent(ev.tags)) |parent_id| {
        note.reply_parent = parent_id;
        note.has_reply_parent = true;
    }

    note.setTime(now_s);
    return note;
}

/// The NIP-10 parent of a reply: the `e` tag marked `reply` wins; with only a
/// `root` marker the note answers the root directly; with no markers at all the
/// LAST `e` tag is the parent (the deprecated positional convention, still
/// common in the wild). `mention` tags never make a note a reply; a quote is
/// not an answer. Null for a note that answers nothing.
pub fn nip10Parent(tags: []const nostr.event.Tag) ?[32]u8 {
    var reply: ?[32]u8 = null;
    var root: ?[32]u8 = null;
    var last_plain: ?[32]u8 = null;
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        const marker = if (tag.len >= 4) tag[3] else "";
        if (std.mem.eql(u8, marker, "reply")) {
            reply = id;
        } else if (std.mem.eql(u8, marker, "root")) {
            root = id;
        } else if (std.mem.eql(u8, marker, "mention")) {
            // A quoted note, not an ancestor.
        } else {
            last_plain = id;
        }
    }
    return reply orelse root orelse last_plain;
}

/// Orders a fetched reply set into conversation order (each reply directly
/// under the note it answers, siblings oldest-first) and stamps every note's
/// nesting depth (1 = a direct reply to the root). Expects `notes` already
/// sorted oldest-first, which is what makes sibling order chronological.
///
/// A reply whose parent is the root, is missing from the set (past the fetch
/// cap, deleted, or never seen), or answers nothing sits at the top level in
/// its chronological place. A parent cycle (malformed events) cannot loop: the
/// visited set admits each note once, and whatever a cycle strands is appended
/// at the top level.
pub fn arrangeThread(notes: []Note, root_event_id: [32]u8) void {
    const n = notes.len;
    if (n < 2) {
        if (n == 1) notes[0].depth = 1;
        return;
    }
    std.debug.assert(n <= thread_reply_cap);
    // Each note's parent INDEX within the set, or `n` for "top level". The
    // scan is O(n^2) over 32-byte compares, which at the 100-reply cap is
    // trivia next to the store query that produced the set.
    var parent: [thread_reply_cap]u16 = undefined;
    for (notes[0..n], 0..) |*note, i| {
        parent[i] = @intCast(n);
        if (!note.has_reply_parent) continue;
        if (std.mem.eql(u8, &note.reply_parent, &root_event_id)) continue;
        for (notes[0..n], 0..) |*cand, j| {
            if (i != j and std.mem.eql(u8, &cand.event_id, &note.reply_parent)) {
                parent[i] = @intCast(j);
                break;
            }
        }
    }
    // The DFS emits a PERMUTATION (conversation order over current indices),
    // so ordering is one O(n) gather through the scratch below, never a sort,
    // which would move the ~1.5KB Note structs O(n log n) times for an order
    // the walk already knows.
    var visited = [_]bool{false} ** thread_reply_cap;
    var order: [thread_reply_cap]u16 = undefined;
    var count: usize = 0;
    const Dfs = struct {
        notes: []Note,
        parent: []const u16,
        visited: []bool,
        order: []u16,
        count: *usize,
        fn visit(self: *const @This(), i: usize, depth: u8) void {
            if (self.visited[i]) return;
            self.visited[i] = true;
            self.notes[i].depth = depth;
            self.order[self.count.*] = @intCast(i);
            self.count.* += 1;
            for (self.parent, 0..) |p, j| {
                if (p == i) self.visit(j, depth +| 1);
            }
        }
    };
    const dfs = Dfs{ .notes = notes, .parent = parent[0..n], .visited = visited[0..n], .order = order[0..n], .count = &count };
    for (0..n) |i| {
        if (parent[i] == n) dfs.visit(i, 1);
    }
    // A cycle's strands: no member ever reached the top level, so seat them
    // there, still oldest-first.
    for (0..n) |i| {
        if (!visited[i]) {
            notes[i].depth = 1;
            order[count] = @intCast(i);
            count += 1;
        }
    }
    for (order[0..n], 0..) |src, dst| g_arrange_scratch[dst] = notes[src];
    @memcpy(notes[0..n], g_arrange_scratch[0..n]);
}

// The gather scratch for `arrangeThread`'s permutation apply. File-scope (not
// stack: ~150KB of Note at the cap) and safe unsynchronized because every
// caller runs on the UI thread: refreshThreadNotes from `update`, and
// threadRepliesFromStore from the view build.
var g_arrange_scratch: [thread_reply_cap]Note = undefined;

/// The thread root the tags declare: the `e` tag marked `root`, or the FIRST
/// non-mention `e` tag in the positional form (NIP-10's deprecated scheme puts
/// the root first and the immediate parent last). Null when the note answers
/// nothing, which is what a root's own tags look like.
///
/// Used to name what a gap in the ancestor chain is: a missing id that IS this
/// root is the thread's opening note, and the ghost row says so.
pub fn nip10Root(tags: []const nostr.event.Tag) ?[32]u8 {
    var first_plain: ?[32]u8 = null;
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, tag[1]) catch continue;
        const marker = if (tag.len >= 4) tag[3] else "";
        if (std.mem.eql(u8, marker, "root")) return id;
        if (std.mem.eql(u8, marker, "mention") or std.mem.eql(u8, marker, "reply")) continue;
        if (first_plain == null) first_plain = id;
    }
    return first_plain;
}

/// Whether the tags carry a NON-mention `e` reference to `id`: a root, reply,
/// or positional ancestor pointer. A mention-marked tag is a quote, not an
/// ancestor tie.
pub fn nip10References(tags: []const nostr.event.Tag, id: [32]u8) bool {
    for (tags) |tag| {
        if (tag.len < 2 or !std.mem.eql(u8, tag[0], "e")) continue;
        if (tag[1].len != 64) continue;
        var tid: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&tid, tag[1]) catch continue;
        if (!std.mem.eql(u8, &tid, &id)) continue;
        const marker = if (tag.len >= 4) tag[3] else "";
        if (!std.mem.eql(u8, marker, "mention")) return true;
    }
    return false;
}

// How many candidates one walk round asks the store for: a multiple of the
// display cap, so the events the gates reject (quotes, foreign repliers,
// cross-round duplicates) do not consume the window genuine replies needed.
// The store answers newest-first, so a round referenced by MORE events than
// this can still cut old ones; the pool just makes that take four hundred
// referers in one round rather than one hundred.
const thread_walk_limit = thread_reply_cap * 4;

/// Collects the ids of every store-resident reply in `root_event_id`'s thread:
/// a breadth-first walk of the `#e` graph out from the root. The walk is what
/// makes SUB-threads whole: a NIP-10 reply tags only the true thread root and
/// its direct parent, so a single `#e = sub-root` query returns just the
/// direct children of a mid-thread note while its deeper descendants (already
/// ingested by the top level's fetch) go unseen.
///
/// Membership is CONNECTIVITY, not co-mention: a candidate joins only when the
/// note it answers (`nip10Parent`) is the level root or already a member, or
/// when it carries a non-mention `e` reference to the level root itself, which
/// keeps a reply whose interior parent never reached the store visible as a
/// top-level row instead of vanishing. A mere `nip10Parent != null` would
/// admit a foreign thread's reply that only QUOTES ours, and then import that
/// thread's whole subtree through the next round's frontier.
///
/// The breadth-first order collects parents in an earlier round than their
/// children, so overflowing the display cap drops subtree tails rather than
/// interior parents. Within one round the store's newest-first `limit` can
/// still cut old referers (see `thread_walk_limit`).
pub fn collectThreadIds(store: *nostr.store.Store, root_event_id: [32]u8, out: *[thread_reply_cap][32]u8) usize {
    // Hex forms of the frontier ids, referenced by the query's tag filter:
    // slot 0 is the root, slot 1+i mirrors out[i].
    var hexes: [thread_reply_cap + 1][64]u8 = undefined;
    var values: [thread_reply_cap][]const u8 = undefined;
    hexLower(&hexes[0], root_event_id);
    var count: usize = 0;
    var frontier_start: usize = 0;
    var first_round = true;
    while (count < out.len) {
        var nvals: usize = 0;
        if (first_round) {
            values[0] = &hexes[0];
            nvals = 1;
        } else {
            for (frontier_start..count) |i| {
                hexLower(&hexes[1 + i], out[i]);
                values[nvals] = &hexes[1 + i];
                nvals += 1;
            }
        }
        if (nvals == 0) break;
        const round_start = count;
        // A tags-ONLY filter: with a kind in the filter the store's index
        // ladder prefers the kind index and streams every kind:1 ever stored,
        // post-filtering on the tag, which is the whole feed history, per round. The
        // tag index streams just the frontier's referers; the kind gate is
        // cheap and ours.
        const tag_filters = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = values[0..nvals] }};
        var result = store.query(std.heap.page_allocator, .{ .tags = &tag_filters, .limit = thread_walk_limit }) catch break;
        defer result.deinit();
        // Round-local fixpoint, admitting OLDEST first (the store answers
        // newest-first): a parent is older than its children, so oldest-first
        // usually connects everything in one pass, and overflowing the cap
        // keeps the conversation's beginning (the parents everything hangs
        // from) rather than its newest tail. Whatever stays unconnected
        // after the fixpoint does not belong to this thread.
        while (count < out.len) {
            var admitted = false;
            var idx: usize = result.events.len;
            while (idx > 0) {
                idx -= 1;
                const ev = result.events[idx];
                if (count >= out.len) break;
                if (ev.kind != 1) continue;
                if (std.mem.eql(u8, &ev.id, &root_event_id)) continue;
                const parent = nip10Parent(ev.tags) orelse continue;
                var connected = std.mem.eql(u8, &parent, &root_event_id) or nip10References(ev.tags, root_event_id);
                if (!connected) {
                    for (out[0..count]) |*member| {
                        if (std.mem.eql(u8, member, &parent)) {
                            connected = true;
                            break;
                        }
                    }
                }
                if (!connected) continue;
                var dup = false;
                for (out[0..count]) |*seen| {
                    if (std.mem.eql(u8, seen, &ev.id)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                out[count] = ev.id;
                count += 1;
                admitted = true;
            }
            if (!admitted) break;
        }
        // The next frontier is exactly this round's finds; none means the
        // closure is complete.
        if (count == round_start) break;
        frontier_start = round_start;
        first_round = false;
    }
    return count;
}

/// One ancestor level's collected reply ids, stamped with the store's event
/// count, so the per-frame render of an OCCLUDED level re-walks the `#e`
/// closure only when the store actually grew, not every frame. UI-thread
/// only, like the arrange scratch above.
const LevelReplies = struct {
    root: [32]u8 = [_]u8{0} ** 32,
    stamp: usize = std.math.maxInt(usize),
    ids: [thread_reply_cap][32]u8 = undefined,
    len: usize = 0,
};
var g_level_replies: [thread_depth_max]LevelReplies = [_]LevelReplies{.{}} ** thread_depth_max;

/// How far up the chain above the focal note is drawn. A thread can be
/// arbitrarily deep, and the walk costs a point read per step, so the chain
/// stops here and SAYS that it stopped (see `AncestorGap.capped`): clicking the
/// topmost ancestor focuses it, and its own chain continues from there.
const thread_ancestor_max = 8;

/// Why the chain above the focal note stops where it does.
pub const AncestorGap = enum {
    /// It does not: the chain reaches the thread's opening note.
    none,
    /// The next note up is not in the store yet. The subscription is out for it.
    missing,
    /// The chain is deeper than `thread_ancestor_max`, so the rest is above what
    /// is drawn.
    capped,
};

/// One ancestor level's chain above the focal note, stamped with the store's
/// event count so the walk (a point read per step) runs when the store grows
/// rather than every frame. UI-thread only, like the reply caches above.
const AncestorChain = struct {
    focal: [32]u8 = [_]u8{0} ** 32,
    stamp: usize = std.math.maxInt(usize),
    /// Oldest first, which is the order they are drawn in.
    ids: [thread_ancestor_max][32]u8 = undefined,
    /// How many body lines each of those notes draws, cached with the walk so an
    /// OCCLUDED level can price its rows without building a single Note. That is
    /// the only thing such a level needs from the chain, and reading eight events
    /// per level per frame to learn it was most of the cost the walk cache set
    /// out to remove.
    lines: [thread_ancestor_max]u8 = [_]u8{0} ** thread_ancestor_max,
    len: usize = 0,
    gap: AncestorGap = .none,
    /// Whether the id the chain stops below is the thread's declared root, which
    /// is the difference between "root note not here yet" and "the note this
    /// answers is not here yet".
    gap_is_root: bool = false,
};
/// One per mounted level: the back-stack plus the open thread.
var g_ancestor_chains: [thread_depth_max + 1]AncestorChain = [_]AncestorChain{.{}} ** (thread_depth_max + 1);

/// Walks from `focal` up its NIP-10 reply chain, collecting the ancestors that
/// are in the store (oldest first) and recording why the walk stopped. Cheap on
/// a repeat call: the result is cached until the store grows or the focal note
/// changes.
fn refreshAncestorChain(chain: *AncestorChain, store: *nostr.store.Store, focal: *const Note, stamp: usize) void {
    chain.* = .{ .focal = focal.event_id, .stamp = stamp };
    if (!focal.has_reply_parent) return;

    // The root the focal note itself declares, so a gap can be named. Read from
    // the store rather than carried on the Note: only this row needs it.
    var declared_root: ?[32]u8 = null;
    if (store.getEvent(std.heap.page_allocator, focal.event_id) catch null) |se| {
        var owned = se;
        defer owned.deinit();
        declared_root = nip10Root(owned.event.tags);
    }

    // Newest first while walking, reversed into the cache at the end.
    var up: [thread_ancestor_max][32]u8 = undefined;
    var up_lines: [thread_ancestor_max]u8 = undefined;
    var n: usize = 0;
    const now = nowSeconds();
    var want = focal.reply_parent;
    // A note that tags ITSELF as its parent would otherwise be walked as its own
    // ancestor and drawn twice in one list, under the same row key.
    if (std.mem.eql(u8, &want, &focal.event_id)) return;
    while (true) {
        if (n == thread_ancestor_max) {
            chain.gap = .capped;
            break;
        }
        var se = (store.getEvent(std.heap.page_allocator, want) catch null) orelse {
            chain.gap = .missing;
            // The ghost row says the relays are being asked for this, so ask
            // them: the thread's own subscription only covers what answers the
            // focal note, never what it answers.
            wantQuote(want);
            break;
        };
        defer se.deinit();
        up[n] = want;
        // Stamped here, where the event is already in hand.
        up_lines[n] = @intFromFloat(ancestorBodyLines(&noteFrom(se.event, now)));
        n += 1;
        if (declared_root == null) declared_root = nip10Root(se.event.tags);
        const parent = nip10Parent(se.event.tags) orelse break;
        // A malformed cycle (a note tagging one of its own descendants, or its
        // own id) would walk forever, so a repeat ends the chain where it
        // repeats. It has NOT reached the thread's opening note, and the row
        // says so rather than claiming the chain is whole.
        if (std.mem.eql(u8, &parent, &focal.event_id)) {
            chain.gap = .missing;
            return finishChain(chain, up[0..n], up_lines[0..n], declared_root, parent);
        }
        for (up[0..n]) |seen| {
            if (std.mem.eql(u8, &seen, &parent)) {
                chain.gap = .missing;
                return finishChain(chain, up[0..n], up_lines[0..n], declared_root, parent);
            }
        }
        want = parent;
    }
    finishChain(chain, up[0..n], up_lines[0..n], declared_root, want);
}

/// Reverses the walk into drawing order and names the gap, if there is one.
fn finishChain(chain: *AncestorChain, up: []const [32]u8, up_lines: []const u8, declared_root: ?[32]u8, stopped_at: [32]u8) void {
    for (up, 0..) |id, i| {
        chain.ids[up.len - 1 - i] = id;
        chain.lines[up.len - 1 - i] = up_lines[i];
    }
    chain.len = up.len;
    chain.gap_is_root = chain.gap == .missing and declared_root != null and
        std.mem.eql(u8, &declared_root.?, &stopped_at);
}

/// One row of the chain above the focal note: an ancestor read from the store,
/// or the gap where the chain stops.
pub const Ancestor = struct {
    note: Note = .{},
    /// How many body lines this row draws. Carried on the row because an
    /// occluded level has no `note` to measure.
    lines: u8 = 0,
    /// `.none` for a real ancestor; anything else makes this row a ghost.
    ghost: AncestorGap = .none,
    /// For a ghost: whether what is missing is the thread's opening note.
    is_root: bool = false,
};

/// Records the FIRST `nostr:nevent`/`note` reference in `note`'s rendered
/// content as a decoded event id plus the byte span of its raw token, so the
/// body can split around it and draw an embedded quote card. A second reference,
/// an `naddr`, or an undecodable token is left as plain text (`.none`).
fn findQuoteRef(note: *Note) void {
    const text = note.content();
    var scratch: [16 * 1024]u8 = undefined;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // The token starts at a `nostr:` prefix, or a bare `nevent1`/`note1`, but
        // only at a word boundary, so one embedded in a URL (`…/nostr:nevent…`)
        // or a longer token is left alone rather than split into a spurious card.
        var body_start = i;
        if (std.mem.startsWith(u8, text[i..], "nostr:")) {
            if (!refPrecededByBoundary(text, i)) continue;
            body_start = i + "nostr:".len;
        } else if (std.mem.startsWith(u8, text[i..], "nevent1") or std.mem.startsWith(u8, text[i..], "note1")) {
            if (!refPrecededByBoundary(text, i)) continue;
        } else continue;

        const rest = text[body_start..];
        if (!std.mem.startsWith(u8, rest, "nevent1") and !std.mem.startsWith(u8, rest, "note1")) continue;
        var j: usize = 0;
        while (j < rest.len and isBech32Char(rest[j])) j += 1;
        const token = rest[0..j];

        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const arena = fba.allocator();
        const id: ?[32]u8 = if (std.mem.startsWith(u8, token, "nevent1")) blk: {
            const ptr = nostr.nip19.decodeNevent(arena, token) catch break :blk null;
            break :blk ptr.id;
        } else (nostr.nip19.decodeNote(arena, token) catch null);

        if (id) |event_id| {
            note.quote = .{ .kind = .event, .id = event_id, .off = @intCast(i), .len = @intCast((body_start - i) + j) };
            return;
        }
    }
}

/// The aspect (height over width) the note's own NIP-92 `imeta` tag declares for
/// `url`, or 0 when it says nothing. An `imeta` tag reads
/// `["imeta", "url https://…", "dim 882x302", …]`; dimensions are sometimes
/// written as floats, so both forms parse.
/// A byte count as a reader reads it: `240 KB`, `1.4 MB`. Decimal units, because
/// that is what the file's own host quotes and what the note author copied.
fn byteSize(arena: std.mem.Allocator, bytes: u32) []const u8 {
    if (bytes < 1000) return std.fmt.allocPrint(arena, "{d} B", .{bytes}) catch "";
    if (bytes < 1_000_000) return std.fmt.allocPrint(arena, "{d} KB", .{bytes / 1000}) catch "";
    const mb = @as(f32, @floatFromInt(bytes)) / 1_000_000.0;
    return std.fmt.allocPrint(arena, "{d:.1} MB", .{mb}) catch "";
}

/// What a note's NIP-92 `imeta` tag says about `url`: its pixel dimensions, its
/// alt text and its blurhash. One walk, because the picture's chrome wants all
/// three and the tag is one place.
pub const Imeta = struct {
    width: u16 = 0,
    height: u16 = 0,
    /// A slice of the EVENT's memory, so it lives as long as the event does. The
    /// caller copies what it wants to keep.
    alt: []const u8 = "",
    blurhash: []const u8 = "",
    /// The file's size in bytes, as the note claims it. The only source there is:
    /// the SDK's fetch response carries no headers, so there is no Content-Length
    /// to read, and with previews off nothing is fetched at all.
    size: u32 = 0,

    /// Height over width, or 0 when the tag says nothing. Knowing the shape
    /// before the bytes arrive is what lets a row reserve exactly the right
    /// space, so nothing shifts when the picture lands.
    pub fn aspect(self: Imeta) f32 {
        if (self.width == 0 or self.height == 0) return 0;
        return @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(self.width));
    }
};

pub fn imetaFor(tags: []const nostr.event.Tag, url: []const u8) Imeta {
    for (tags) |tag| {
        if (tag.len == 0 or !std.mem.eql(u8, tag[0], "imeta")) continue;
        var matches_url = false;
        var found: Imeta = .{};
        for (tag[1..]) |field| {
            if (std.mem.startsWith(u8, field, "url ")) {
                matches_url = std.mem.eql(u8, std.mem.trim(u8, field[4..], " "), url);
            } else if (std.mem.startsWith(u8, field, "dim ")) {
                const dim = std.mem.trim(u8, field[4..], " ");
                const x = std.mem.indexOfScalar(u8, dim, 'x') orelse continue;
                // Written as floats by some clients, so parse wide and narrow.
                const w = std.fmt.parseFloat(f32, dim[0..x]) catch continue;
                const h = std.fmt.parseFloat(f32, dim[x + 1 ..]) catch continue;
                if (w > 0 and h > 0 and w < 65536 and h < 65536) {
                    found.width = @intFromFloat(w);
                    found.height = @intFromFloat(h);
                }
            } else if (std.mem.startsWith(u8, field, "alt ")) {
                found.alt = std.mem.trim(u8, field[4..], " ");
            } else if (std.mem.startsWith(u8, field, "size ")) {
                found.size = std.fmt.parseInt(u32, std.mem.trim(u8, field[5..], " "), 10) catch 0;
            } else if (std.mem.startsWith(u8, field, "blurhash ")) {
                found.blurhash = std.mem.trim(u8, field["blurhash ".len..], " ");
            }
        }
        if (matches_url) return found;
    }
    return .{};
}

pub fn imetaAspect(tags: []const nostr.event.Tag, url: []const u8) f32 {
    for (tags) |tag| {
        if (tag.len == 0 or !std.mem.eql(u8, tag[0], "imeta")) continue;
        var matches_url = false;
        var aspect: f32 = 0;
        for (tag[1..]) |field| {
            if (std.mem.startsWith(u8, field, "url ")) {
                matches_url = std.mem.eql(u8, std.mem.trim(u8, field[4..], " "), url);
            } else if (std.mem.startsWith(u8, field, "dim ")) {
                const dim = std.mem.trim(u8, field[4..], " ");
                const x = std.mem.indexOfScalar(u8, dim, 'x') orelse continue;
                const w = std.fmt.parseFloat(f32, dim[0..x]) catch continue;
                const h = std.fmt.parseFloat(f32, dim[x + 1 ..]) catch continue;
                if (w > 0 and h > 0) aspect = h / w;
            }
        }
        if (matches_url and aspect > 0) return aspect;
    }
    return 0;
}

/// Whether a URL names an image file. By extension, which is what Nostr media
/// hosts serve; a link without one is an ordinary link.
pub fn looksLikeImageUrl(url: []const u8) bool {
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp" };
    const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path = url[0..path_end];
    for (exts) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

/// The first image URL in `content`, or null. Recognised by extension, which is
/// what Nostr media hosts serve; a link without one stays ordinary text.
pub fn firstImageUrl(content: []const u8) ?[]const u8 {
    const exts = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp" };
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] != 'h') continue;
        if (!std.mem.startsWith(u8, content[i..], "http://") and !std.mem.startsWith(u8, content[i..], "https://")) continue;
        // The URL runs to the first whitespace.
        var j = i;
        while (j < content.len and !std.ascii.isWhitespace(content[j])) j += 1;
        const url = content[i..j];
        // Ignore a trailing bare query string when matching the extension.
        const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const path = url[0..path_end];
        for (exts) |ext| {
            if (std.ascii.endsWithIgnoreCase(path, ext)) return url;
        }
        i = j;
    }
    return null;
}

/// Copies note content into `dst`, rewriting NIP-27 `nostr:npub…`/`nostr:nprofile…`
/// mentions into a readable `@name` (from the profile cache) or a short `@npub`,
/// and dropping `omit` (the URL rendered as a picture) wherever it appears.
/// Plain text is copied one whole codepoint at a time and stops at `dst`'s
/// capacity, so the buffer never ends mid-sequence. Returns the byte length.
pub fn renderContent(dst: []u8, src: []const u8, omit: []const u8) usize {
    // Mention decoding needs an allocator for bech32 scratch; a stack buffer
    // covers it without touching the heap for every note parsed. A pathological
    // mention that will not fit simply stays as its raw token.
    var scratch: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const arena = fba.allocator();

    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (omit.len > 0 and std.mem.startsWith(u8, src[i..], omit)) {
            i += omit.len;
            continue;
        }
        if (parseMentionAt(arena, src, i)) |m| {
            var label_buf: [80]u8 = undefined;
            const label = mentionLabel(m.pubkey, &label_buf);
            if (out + label.len > dst.len) break;
            @memcpy(dst[out..][0..label.len], label);
            out += label.len;
            i = m.end;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        const take = @min(seq_len, src.len - i);
        if (out + take > dst.len) break;
        @memcpy(dst[out..][0..take], src[i..][0..take]);
        out += take;
        i += take;
    }
    // Lifting a URL out can leave whitespace stranded at either edge.
    const trimmed = std.mem.trim(u8, dst[0..out], " \t\r\n");
    if (trimmed.len != out) {
        std.mem.copyForwards(u8, dst[0..trimmed.len], trimmed);
        return trimmed.len;
    }
    return out;
}

/// A parsed `nostr:` mention at `src[i]`: the byte just past its token, and the
/// referenced pubkey. Null when `src[i]` is not the start of one.
fn parseMentionAt(arena: std.mem.Allocator, src: []const u8, i: usize) ?struct { end: usize, pubkey: [32]u8 } {
    const prefix = "nostr:";
    var body_start = i;
    if (std.mem.startsWith(u8, src[i..], prefix)) {
        body_start = i + prefix.len;
    } else {
        // A bare npub/nprofile counts too (plenty of clients write them without
        // the scheme), but only at a word boundary, so one inside a URL or a
        // longer token is left alone.
        const bare = std.mem.startsWith(u8, src[i..], "npub1") or std.mem.startsWith(u8, src[i..], "nprofile1");
        if (!bare) return null;
        if (i > 0 and (isBech32Char(src[i - 1]) or src[i - 1] == '/' or src[i - 1] == ':')) return null;
    }
    const rest = src[body_start..];
    var j: usize = 0;
    while (j < rest.len and isBech32Char(rest[j])) j += 1;
    if (j == 0) return null;
    const token = rest[0..j];
    const end = body_start + j;

    if (std.mem.startsWith(u8, token, "npub1")) {
        const pk = nostr.nip19.decodeNpub(arena, token) catch return null;
        return .{ .end = end, .pubkey = pk };
    }
    if (std.mem.startsWith(u8, token, "nprofile1")) {
        const pp = nostr.nip19.decodeNprofile(arena, token) catch return null;
        return .{ .end = end, .pubkey = pp.pubkey };
    }
    return null;
}

/// Writes `@` + the cached display name (or a short npub) for `pubkey` into
/// `buf`, returning the written slice. `buf` should be at least 80 bytes.
fn mentionLabel(pubkey: [32]u8, buf: []u8) []const u8 {
    buf[0] = '@';
    if (lookupProfile(pubkey)) |p| {
        if (p.name_len > 0) {
            const n = @min(p.name_len, buf.len - 1);
            @memcpy(buf[1..][0..n], p.name_buf[0..n]);
            return buf[0 .. 1 + n];
        }
    }
    // No name for this one: ask for it, so the next rebuild can show it.
    wantProfile(pubkey);
    const npub = abbreviateNpub(buf[1..], pubkey);
    return buf[0 .. 1 + npub.len];
}

/// Whether `c` is a bech32 data character (lowercase letter or digit), the run
/// that follows a `nostr:` prefix.
fn isBech32Char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// Whether `c` continues a hashtag word (letters, digits, or underscore).
fn isHashtagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether an event reference (`nostr:nevent1…`/`note1…`/`naddr1…`, or a bare one
/// at a word boundary) begins at `text[i]`, so a run can be accent-styled. Only
/// at a word boundary, so a `nostr:` or bare token embedded in a URL is skipped.
fn isEventRefStart(text: []const u8, i: usize) bool {
    if (!refPrecededByBoundary(text, i)) return false;
    var s = text[i..];
    if (std.mem.startsWith(u8, s, "nostr:")) s = s["nostr:".len..];
    return std.mem.startsWith(u8, s, "nevent1") or std.mem.startsWith(u8, s, "note1") or std.mem.startsWith(u8, s, "naddr1");
}

/// Whether `text[i]` sits at a word boundary for a nostr reference: the start, or
/// after a character that could not be part of a URL or bech32 run. Keeps a
/// `nostr:nevent…`/bare token embedded in a URL from being matched.
fn refPrecededByBoundary(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    const c = text[i - 1];
    return !(std.ascii.isAlphanumeric(c) or c == '/' or c == ':' or c == '.' or c == '-' or c == '_' or c == '@');
}

fn setAuthor(note: *Note, pubkey: [32]u8) void {
    const s = abbreviateNpub(&note.author_buf, pubkey);
    note.author_len = @intCast(s.len);
}

/// Writes an abbreviated npub (`npub1p9x8h…7k2q`), the canonical Nostr
/// identifier, for `pubkey` into `out`, returning the written slice; falls back
/// to a short hex prefix if bech32 encoding fails. The result always lives in
/// `out` (never the scratch buffer), so the caller can hold it safely. `out`
/// should be at least 20 bytes for the abbreviated form. bech32's encoder grows
/// an ArrayList and hands back an owned slice, so on a fixed buffer the
/// intermediate reallocations accumulate well past the ~63-char result; 1 KiB of
/// scratch covers that churn without touching the heap.
fn abbreviateNpub(out: []u8, pubkey: [32]u8) []const u8 {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch {
        const hexdigits = "0123456789abcdef";
        var n: usize = 0;
        while (n < 16 and n + 1 < out.len) : (n += 2) {
            out[n] = hexdigits[pubkey[n / 2] >> 4];
            out[n + 1] = hexdigits[pubkey[n / 2] & 0x0f];
        }
        return out[0..n];
    };
    if (npub.len > 18) {
        if (std.fmt.bufPrint(out, "{s}…{s}", .{ npub[0..12], npub[npub.len - 5 ..] })) |s| return s else |_| {}
    }
    const n = @min(npub.len, out.len);
    @memcpy(out[0..n], npub[0..n]);
    return out[0..n];
}

/// The largest prefix of `s` no longer than `max` that ends on a UTF-8
/// codepoint boundary (never mid-sequence).
fn utf8SafeLen(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

// -------------------------------------------------------------------- msg

/// The chrome's anchored menus. These are floating surfaces positioned against
/// their trigger, so each one is drawn as the trigger's sibling inside a stack
/// and rendered only while it is the open one.
pub const ChromeMenu = enum { none, scope, relays, account, outbox };

pub const Msg = union(enum) {
    /// The repeating refresh timer fired: reconcile the feed with the store.
    tick: native_sdk.EffectTimer,
    /// A text edit in the composer, mirrored into the draft buffer.
    draft_edit: canvas.TextInputEvent,
    /// Post the current draft: sign, store locally, and publish to the pool.
    post,
    /// Open the compose sheet (a guest is routed to the join screen instead).
    open_compose,
    /// Dismiss the compose sheet.
    close_compose,
    /// Open the first-intent join sheet (create / bring a key / use a signer).
    open_join,
    /// Dismiss the join sheet; a remembered intent is forgotten with it.
    close_join,
    /// The sheet's primary: mint a local identity and replay the intent.
    join_create,
    /// The sheet's import path: open the Signet window (a separate process),
    /// so a pasted key never enters Plaza. The remembered intent survives.
    open_signet_import,
    /// Leave the join screen back to the feed; reading never needs an identity.
    keep_browsing,
    /// The join sheet's "Use your own signer": go to the focused bunker input.
    open_bunker,
    /// Back out of the bunker input to the ladder.
    close_bunker,
    /// Hide the guest strip for this session.
    dismiss_guest_strip,
    /// Open one of the chrome's anchored menus (or close it, when it is already
    /// the open one, so a trigger toggles).
    toggle_menu: ChromeMenu,
    /// Escape: closes whatever is on top, one layer at a time. Which layer that
    /// is depends on the model, so the key names the intent and `update`
    /// decides, rather than four shortcuts racing to own the same key.
    dismiss_top,
    /// Replaces the `@word` being typed with a real reference to this key.
    insert_mention: [32]u8,
    /// Close whatever chrome menu is open (Escape, or a press outside it).
    close_menu,
    /// Stop talking to the relays until resumed, or start again.
    toggle_relays_paused,
    /// Jump the feed to its newest note.
    jump_to_newest,
    /// Reveal the next page of a thread's replies.
    show_more_replies,
    /// Show or re-hide the replies from outside the follow graph.
    toggle_outside_replies,
    /// Sign out, asked for from the account menu: opens Settings with the
    /// confirmation showing, so the menu never signs anyone out on one press.
    open_settings_logout,
    /// Copy a note's nevent address to the clipboard.
    copy_nevent: i64,
    /// Open a note on the web (njump), for sharing it outside nostr.
    open_web: i64,
    /// A text edit in the name beat's field.
    name_edit: canvas.TextInputEvent,
    /// Publish the chosen name as the account's kind:0 and move on.
    name_save,
    /// Skip the name beat; the account stays nameless for now.
    name_skip,
    /// From the backup nudge: open Settings at the backup card.
    backup_now,
    /// Dismiss the backup nudge for this session.
    backup_later,
    /// Onboarding: create a fresh local identity and enter the feed.
    create_identity,
    /// A text edit in the onboarding sign-in field.
    login_edit: canvas.TextInputEvent,
    /// Onboarding: sign in with the pasted nsec or bunker link and enter the feed.
    login_submit,
    /// Open the Settings screen.
    open_settings,
    /// Return from Settings to the feed.
    close_settings,
    /// Reveal (or hide) the local secret key for backup.
    toggle_nsec,
    /// Copy the signed-in npub to the clipboard.
    copy_npub,
    /// Copy the local secret key (nsec) to the clipboard.
    copy_nsec,
    /// Ask to log out: show the confirmation.
    logout_request,
    /// Dismiss the logout confirmation.
    logout_cancel,
    /// Confirm logout: wipe the session (and a local key) and return to onboarding.
    logout_confirm,
    /// The signer daemon exited (logged; the watchdog and respawn are later).
    helper_exited: native_sdk.EffectExit,
    /// The signer daemon's /pubkey health-check answered.
    helper_pubkey: native_sdk.EffectResponse,
    /// A /setup (create) answered: adopt the new helper identity.
    helper_setup: native_sdk.EffectResponse,
    /// A /sign answered: ingest and publish the signed event.
    helper_signed: native_sdk.EffectResponse,
    /// An avatar fetch finished: register the image or fall back to initials.
    avatar_fetched: native_sdk.EffectResponse,
    /// A media fetch finished: decode, downscale if needed, and register it.
    media_fetched: native_sdk.EffectResponse,
    /// A NIP-05 well-known lookup finished: mark the author verified on a match.
    nip05_verified: native_sdk.EffectResponse,
    /// A page that was asked what it says about itself.
    link_fetched: native_sdk.EffectResponse,
    /// A text edit in the Settings media-proxy field.
    proxy_edit: canvas.TextInputEvent,
    /// Save the media-proxy setting.
    proxy_save,
    /// Flips whether the app reaches out for what notes point at.
    previews_toggle,
    /// The feed scrolled: remember where, so images load around the viewport.
    feed_scrolled: canvas.ScrollState,
    /// A link in a note was pressed: open it in the browser.
    open_url: []const u8,
    /// The animation timer fired: advance any playing GIFs.
    animate: native_sdk.EffectTimer,
    /// The profile-fetch timer: re-ask for wanted metadata, decoupled from the
    /// view refresh (see `profile_timer_key`).
    profiles: native_sdk.EffectTimer,
    /// Expand a note's picture to fill the window.
    expand_image: i64,
    /// One picture, asked for by the reader while previews are off.
    load_image: i64,
    /// Dismiss the expanded picture.
    close_image,
    /// Toggle a like on a note (by id): publish a kind:7 reaction, or a kind:5
    /// deletion to un-like. A guest press is remembered and routed to the join.
    like: i64,
    /// Open a note's thread (by id): the focused note and its replies.
    open_thread: i64,
    /// Open a quoted event as a thread (by its full 32-byte id).
    open_event: [32]u8,
    /// Leave the thread back to the feed.
    close_thread,
    /// A text edit in the thread's reply composer.
    reply_edit: canvas.TextInputEvent,
    /// Publish the reply composer's text as a reply to the open thread's note.
    reply_submit,
    /// Toggle a long note's body (by id) between the collapsed fold and full.
    toggle_expand: i64,
    /// The reader reached the end of the feed: ask the store for another page.
    load_older,

    // Dispatched from Zig rather than markup: the effect results, and every
    // action on the feed screen (a Zig view now, not a markup file).
    pub const view_unbound = .{ "tick", "animate", "profiles", "avatar_fetched", "media_fetched", "draft_edit", "post", "open_compose", "close_compose", "open_join", "close_join", "join_create", "open_signet_import", "open_bunker", "close_bunker", "nip05_verified", "link_fetched", "dismiss_guest_strip", "name_edit", "name_save", "name_skip", "backup_now", "backup_later", "helper_exited", "helper_pubkey", "helper_setup", "helper_signed", "open_settings", "feed_scrolled", "open_url", "expand_image", "load_image", "close_image", "like", "open_thread", "open_event", "close_thread", "reply_edit", "reply_submit", "toggle_expand", "load_older" };
};

// ---------------------------------------------------------------- app + view

pub const AppUi = canvas.Ui(Msg);

// The two static screens stay declarative markup, compiled into the view at
// build time (so their bindings are still checked, now by the compiler). The
// feed is hand-written below: an inline image needs a runtime `ImageId`
// reference, which the markup grammar deliberately does not carry, so a media
// feed has to be a Zig view.
const OnboardingView = canvas.CompiledMarkupView(Model, Msg, @embedFile("onboarding.native"));
const SettingsView = canvas.CompiledMarkupView(Model, Msg, @embedFile("settings.native"));

/// The root view: one screen at a time, chosen by the stage, with an expanded
/// picture layered over it when one is open.
pub fn appView(ui: *AppUi, model: *const Model) AppUi.Node {
    const base = switch (model.stage) {
        .onboarding => OnboardingView.build(ui, model),
        .settings => SettingsView.build(ui, model),
        .ready => feedView(ui, model),
    };
    if (model.expanded_note) |note_id| {
        if (model.noteById(note_id)) |note| {
            // Layered OVER the feed rather than replacing it, so the scroll
            // region stays mounted and holds its offset. Swapping the tree out
            // unmounts it, and closing would drop the reader back at the top.
            return ui.stack(.{ .grow = 1 }, .{ base, imageViewer(ui, note) });
        }
    }
    if (model.stage == .ready and model.joining) {
        return ui.stack(.{ .grow = 1 }, .{ base, joinSheet(ui, model) });
    }
    if (model.stage == .ready and model.naming) {
        return ui.stack(.{ .grow = 1 }, .{ base, nameSheet(ui, model) });
    }
    if (model.stage == .ready and model.composing) {
        return ui.stack(.{ .grow = 1 }, .{ base, composeSheet(ui, model) });
    }
    if (model.stage == .ready and model.toast_until != 0) {
        return ui.stack(.{ .grow = 1 }, .{ base, toastOverlay(ui, model) });
    }
    return base;
}

/// The name beat: one optional ask after creating an identity, so the account
/// is not blank. Fully skippable; the remembered intent replays either way.
fn nameSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .name_skip,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = "Name" },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .start }, .{
            modalCard(ui, 372, ui.column(.{ .grow = 1, .gap = 12, .padding = 20 }, .{
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = "Want a name on it?", .weight = .bold, .scale = 1.3 }},
                ),
                ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Shown with your notes. Change it any time."),
                ui.el(.textarea, .{
                    .text = model.name_draft(),
                    .placeholder = "A name people will see",
                    .on_input = AppUi.inputMsg(.name_edit),
                    .on_submit = .name_save,
                    .height = 44,
                }, .{}),
                ui.row(.{ .gap = 8, .cross = .center }, .{
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .name_skip }, "Skip"),
                    ui.spacer(1),
                    ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.name_empty(), .on_press = .name_save }, "Save"),
                }),
            })),
        }),
    });
}

/// A small confirming toast, bottom center, retired by the tick.
fn toastOverlay(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .grow = 1, .main = .end, .cross = .center, .padding = 24 }, .{
        ui.row(.{ .padding = 10, .style = .{ .background = p.surface_toast, .border = p.border_modal, .radius = 10, .stroke_width = 1 } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_body } }, model.toast_text()),
        }),
    });
}

/// The first-intent sheet: the join ladder over the dimmed feed. Three ways in,
/// most confident first, and always the way back to reading. When the guest
/// reached for the composer, the sheet says the note is waiting.
fn joinSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .close_join,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = "Join" },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .start }, .{
            if (model.bunker_mode) bunkerCard(ui, model) else joinLadderCard(ui, model),
        }),
    });
}

/// The context line when a guest reached for a like: names whose note it was, so
/// the sheet explains why it appeared. Falls back to a generic line if the note
/// has scrolled out of the window.
fn pendingLikeText(ui: *AppUi, model: *const Model) []const u8 {
    if (model.noteById(model.pending_like)) |note| {
        return std.fmt.allocPrint(ui.arena, "Your like on {s}'s note is waiting.", .{note.author()}) catch "Your like is waiting.";
    }
    return "Your like is waiting.";
}

/// The join ladder: three ways in, most confident first, always the way back.
/// The shared modal card: the SDK `.card` element paints the rounded, bordered
/// surface (a plain column does not paint its background at all), holding a
/// single content column so the sheet reads as a raised, bordered panel.
fn modalCard(ui: *AppUi, width: f32, inner: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.el(.card, .{ .width = width, .style = .{ .background = p.surface_modal, .border = p.border_modal, .radius = 14, .stroke_width = 1 } }, .{inner});
}

fn joinLadderCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return modalCard(ui, 372, ui.column(.{ .grow = 1, .gap = 12, .padding = 20 }, .{
        if (model.pending_compose)
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.status_warning } }, "Your note is waiting.")
        else if (model.pending_like != 0)
            ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.status_warning } }, pendingLikeText(ui, model))
        else
            ui.spacer(0),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_primary } },
            &.{.{ .text = "How do you want to join?", .weight = .bold, .scale = 1.3 }},
        ),
        ui.text(
            .{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } },
            "Everything here is signed with a key of your own, not an account someone holds for you.",
        ),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{ .text = "NEW HERE", .monospace = true, .scale = 0.85 }},
        ),
        ui.button(.{ .variant = .primary, .on_press = .join_create }, "Create your identity"),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Ready in seconds. Nothing to write down."),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{ .text = "ALREADY ON NOSTR", .monospace = true, .scale = 0.85 }},
        ),
        ui.button(.{ .on_press = .open_signet_import }, "Bring your key"),
        ui.button(.{ .on_press = .open_bunker }, "Use your own signer"),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_join }, "Keep browsing"),
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_faint_alt } }, "Reading never needs an identity."),
        }),
    }));
}

/// The focused bunker step: the user already chose to use their own signer, so
/// this is one field, not the whole ladder again. Paste the link, connect.
fn bunkerCard(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return modalCard(ui, 372, ui.column(.{ .grow = 1, .gap = 12, .padding = 20 }, .{
        ui.row(.{ .cross = .center, .gap = 6 }, .{
            ui.el(.data_row, .{ .on_press = .close_bunker, .padding = 4, .style = .{ .quiet_hover = true }, .semantics = .{ .label = "Back" } }, .{
                ui.icon(.{ .width = 16, .height = 16, .style = .{ .foreground = p.text_muted } }, "chevron-left"),
            }),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Connect your signer", .weight = .bold, .scale = 1.3 }},
            ),
        }),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, "Paste the bunker link your signer gave you. Your key stays in your signer, Plaza never sees it."),
        ui.el(.textarea, .{
            .text = model.login_draft(),
            .placeholder = "bunker://…",
            .on_input = AppUi.inputMsg(.login_edit),
            .on_submit = .login_submit,
            .height = 56,
        }, .{}),
        ui.text(.{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_muted } }, model.login_status()),
        ui.button(.{ .variant = .primary, .disabled = model.login_empty(), .on_press = .login_submit }, "Connect"),
    }));
}

/// The compose sheet: a modal over the feed with the note field and the actions.
/// On demand from the titlebar's "New note", so the feed is not sharing the
/// window with a permanent composer. Escape or a click outside closes it.
fn composeSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .close_compose,
        .style_tokens = .{ .background = .scrim },
        .semantics = .{ .label = "New note" },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .start }, .{
            ui.el(.card, .{
                .width = compose_sheet_width,
                .padding = 0.01,
                .style = .{ .background = p.surface_sheet, .border = p.border_window, .radius = 12, .stroke_width = 1 },
            }, .{
                ui.column(.{ .gap = 0 }, .{
                    // The header band: a title and nothing else, so the sheet
                    // says what it is before the eye reaches the field.
                    ui.row(.{ .height = compose_header_height, .cross = .center, .main = .center, .gap = 0 }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_primary } },
                            &.{.{ .text = "New note", .weight = .medium, .scale = menu_scale }},
                        ),
                    }),
                    ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
                    // The writer and their words, side by side: the disc says
                    // whose voice this is, which is the one thing a composer
                    // must not leave ambiguous when a signer can be swapped.
                    ui.row(.{ .gap = 0, .cross = .start }, .{
                        hgap(ui, 18),
                        ui.column(.{ .gap = 0 }, .{
                            vgap(ui, 16),
                            meAvatar(ui, avatar_size),
                        }),
                        hgap(ui, 12),
                        ui.column(.{ .grow = 1, .gap = 0 }, .{
                            vgap(ui, 16),
                            ui.el(.textarea, .{
                                .text = model.draft(),
                                .placeholder = "What's on your mind?",
                                .on_input = AppUi.inputMsg(.draft_edit),
                                .on_submit = .post,
                                .height = compose_editor_height,
                                .style = .{ .background = p.surface_sheet, .border = p.surface_sheet, .stroke_width = 0 },
                            }, .{}),
                            // Under the field, because the caret cannot be
                            // located and a picker that floats elsewhere is a
                            // guess about where the reader is looking.
                            mentionPicker(ui, model),
                            vgap(ui, 14),
                        }),
                        hgap(ui, 18),
                    }),
                    ui.separator(.{ .style = .{ .foreground = p.divider_row, .background = p.divider_row } }),
                    // What pressing Post will do, in the terms that matter: how
                    // far the note goes, and that nothing here will truncate it.
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 18),
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_dim } },
                            &.{.{ .text = composeReach(ui), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        ui.spacer(1),
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = "Cmd + Enter", .monospace = true, .scale = mono_hint_scale }},
                        ),
                        hgap(ui, 10),
                        ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_compose }, "Cancel"),
                        hgap(ui, 4),
                        ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.draft_empty(), .on_press = .post }, "Post"),
                        hgap(ui, 18),
                    }),
                    vgap(ui, 12),
                }),
            }),
        }),
    });
}

/// Replaces the `@word` being typed with a real `nostr:npub…` reference.
///
/// A plain `@name` is a string; only the reference is a link that another
/// client can resolve to a person, and it is what the note's own renderer turns
/// back into a name when it is read. The picker exists to make that the easy
/// path rather than the knowledgeable one.
fn insertMention(model: *Model, pubkey: [32]u8) void {
    const text = model.draft();
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return;
    var buf: [note_content_cap]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch return;
    const written = std.fmt.bufPrint(&buf, "{s}nostr:{s} ", .{ text[0..at], npub }) catch return;
    model.draft_buffer = @TypeOf(model.draft_buffer).init(written);
}

/// One candidate for a mention, and why it is where it is in the list.
const MentionCandidate = struct {
    pubkey: [32]u8,
    name: []const u8,
    handle: []const u8,
    verified: bool,
    /// Lower sorts first. The design's ranking is follows, then follows-you,
    /// then everyone the app has seen; the middle tier needs the follows' own
    /// contact lists, which a later milestone builds, so it is empty here and
    /// the code is shaped to take it.
    tier: u8,
};

const mention_tier_follows: u8 = 0;
const mention_tier_follows_you: u8 = 1;
const mention_tier_seen: u8 = 2;
/// How many names the picker offers at once. A list longer than this is a
/// search, which is a different surface.
const mention_rows_max = 6;

/// The word being typed after an `@`, or null when the caret is not in one.
/// Only ever the LAST such run in the draft, because that is the one being
/// written: an `@name` earlier in the note is already said.
pub fn mentionQuery(text: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return null;
    // An `@` mid-word is an email or a handle already written, not a mention
    // being composed.
    if (at > 0) {
        const before = text[at - 1];
        if (!std.ascii.isWhitespace(before)) return null;
    }
    const word = text[at + 1 ..];
    // A space ends it: the reader has moved on and is no longer picking.
    for (word) |c| {
        if (std.ascii.isWhitespace(c)) return null;
    }
    return word;
}

/// The names to offer for `query`, best first. Matches on the display name and
/// on the handle, because a reader types whichever they remember.
fn mentionCandidates(ui: *AppUi, query: []const u8) []const MentionCandidate {
    const out = ui.arena.alloc(MentionCandidate, mention_rows_max) catch return &.{};
    var n: usize = 0;
    for (&g_profiles) |*pr| {
        if (!pr.used or n == out.len) continue;
        const name = pr.name();
        const user = pr.username();
        if (name.len == 0 and user.len == 0) continue;
        if (query.len > 0 and !startsWithFold(name, query) and !startsWithFold(user, query)) continue;
        out[n] = .{
            .pubkey = pr.pubkey,
            .name = if (name.len > 0) name else user,
            .handle = user,
            .verified = pr.nip05_state == .verified,
            // Everyone in the pack is someone the reader follows; anyone else
            // is someone the app has merely seen.
            .tier = if (inFollowGraph(pr.pubkey)) mention_tier_follows else mention_tier_seen,
        };
        n += 1;
    }
    std.mem.sort(MentionCandidate, out[0..n], {}, struct {
        fn lt(_: void, a: MentionCandidate, b: MentionCandidate) bool {
            if (a.tier != b.tier) return a.tier < b.tier;
            return a.name.len < b.name.len;
        }
    }.lt);
    return out[0..n];
}

/// Case-insensitive prefix match, which is how a reader types a name.
fn startsWithFold(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// The picker: the names the reader might mean, under the field they are typing
/// in. Anchored to the field rather than the caret, which cannot be located
/// (0.5), so it hangs under the whole editor.
fn mentionPicker(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const query = mentionQuery(model.draft()) orelse return ui.spacer(0);
    const names = mentionCandidates(ui, query);
    if (names.len == 0) return ui.spacer(0);
    const rows = ui.arena.alloc(AppUi.Node, names.len + 1) catch return ui.spacer(0);
    for (names, rows[0..names.len], 0..) |c, *row, i| {
        const tint = avatarTint(c.pubkey);
        const hexdigits = "0123456789abcdef";
        row.* = ui.el(.list_item, .{
            .padding = 0.01,
            .cross = .center,
            .on_press = Msg{ .insert_mention = c.pubkey },
            .style = .{ .radius = 6, .background = if (i == 0) p.surface_menu_selected else null },
            .semantics = .{ .role = .button, .label = c.name, .focusable = true },
        }, .{
            hgap(ui, 8),
            ui.avatar(.{
                .image = 0,
                .width = 24,
                .height = 24,
                .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
            }, ui.fmt("{c}{c}", .{ hexdigits[c.pubkey[0] >> 4], hexdigits[c.pubkey[0] & 0x0f] })),
            hgap(ui, 9),
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = c.name, .weight = .medium, .scale = menu_scale }}),
            if (c.verified) hgap(ui, 5) else ui.spacer(0),
            if (c.verified)
                ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle")
            else
                ui.spacer(0),
            hgap(ui, 6),
            if (c.handle.len > 0)
                ui.paragraph(.{ .style = .{ .foreground = p.accent_identity } }, &.{.{ .text = ui.fmt("@{s}", .{c.handle}), .scale = mono_row_scale }})
            else
                ui.spacer(0),
            ui.spacer(1),
            hgap(ui, 8),
        });
    }
    // What pressing one does, said once at the foot rather than per row.
    rows[names.len] = ui.column(.{ .gap = 0 }, .{
        vgap(ui, 2),
        ui.separator(.{ .style = .{ .foreground = p.border_menu, .background = p.border_menu } }),
        vgap(ui, 5),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = "inserts a nostr: link, not just a name", .monospace = true, .scale = mono_chip_scale }},
            ),
        }),
        vgap(ui, 3),
    });
    return menuSurfacePlaced(ui, 320, .below, .start, rows);
}

/// How far a note will go, said before it goes rather than after: the relays
/// that will take a write, and that Plaza imposes no length of its own.
fn composeReach(ui: *AppUi) []const u8 {
    const live = liveRelayCount();
    if (live == 0) return "no relay is answering · it will wait in the outbox";
    return ui.fmt("posts to {d} {s} · no length limit", .{ live, if (live == 1) "relay" else "relays" });
}

/// The expanded picture, filling the window over the feed. The registry decodes
/// at most 512 pixels on a side, so rather than upscale a small copy into a
/// blur, this shows it as large as it honestly goes and offers the
/// full-resolution original in the browser. Pressing the backdrop closes it,
/// which also stops presses reaching the feed underneath.
fn imageViewer(ui: *AppUi, note: *const Note) AppUi.Node {
    const image_id = note.media_id();
    // A dialog, not a bare column: modal surfaces paint their own opaque
    // surface and always claim their own input, so the feed underneath neither
    // shows through nor scrolls, and Escape or a click outside closes it.
    // Stacking kinds layer their children, so the contents go in a column.
    return ui.el(.dialog, .{
        .grow = 1,
        .padding = 16,
        .on_dismiss = .close_image,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "Expanded image" },
    }, .{
        ui.column(.{ .grow = 1, .gap = 12, .cross = .stretch }, .{
            // The picture needs a definite box: an image is a leaf with no
            // intrinsic size, so it draws nothing unless a stretching parent
            // hands it one (a centred column collapses its width to zero).
            ui.row(.{ .grow = 1, .cross = .stretch }, .{
                if (image_id != 0) blk: {
                    var node = ui.image(.{
                        .image = image_id,
                        .grow = 1,
                        .semantics = .{ .label = "Expanded image" },
                    });
                    node.widget.image_fit = .contain;
                    break :blk node;
                } else ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Still loading…"),
            }),
            ui.row(.{ .gap = 8, .cross = .center }, .{
                ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_image }, "Close"),
                ui.spacer(1),
                ui.button(.{ .size = .sm, .on_press = Msg{ .open_url = note.imageUrl() } }, "Open original"),
            }),
        }),
    });
}

/// The one options value both `virtualWindow` and `virtualList` read. The MODEL
/// owns the notes; the runtime only ever sees how many there are, an estimate
/// per row, and the window it asked for.
fn feedOptions(model: *const Model) AppUi.VirtualListOptions {
    return .{
        .id = "feed",
        .item_count = model.notes_len,
        // Variable-extent mode: cards are as tall as their wrapped text and
        // their picture. The estimate prices unbuilt rows; the engine patches in
        // measured heights as rows mount, and anchors the viewport so those
        // corrections never move what the reader is looking at.
        .item_extent = 0,
        .extent_estimate = noteExtentEstimate,
        .extent_context = model,
        // No gap between rows: the hairline under each row is the separation,
        // so a border can mean something (a quote, a reply) and rows do not
        // float apart with the divider lost in the space.
        .gap = 0,
        // No list inset: the row inset was narrower than the reading column, so
        // the column overflowed it on the right (flush) while the left inset read
        // as a gap. At 0 the centered reading column sits symmetric in the feed.
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        // Only bare builds (tests, previews) read this: under the app the
        // runtime supplies the real viewport. Without it a test resolves an
        // empty window and renders no rows at all.
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Feed" },
        .on_reach_end = .load_older,
    };
}

/// A cheap height estimate for the note at `index`, from model facts only
/// (never layout): the card's chrome, its wrapped lines, and its picture.
fn noteExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    const model: *const Model = @ptrCast(@alignCast(context orelse return 96));
    const i: usize = @intCast(index);
    if (i >= model.notes_len) return feed_row_chrome;
    return noteRowEstimate(&model.notes[i], feed_row_chrome);
}

/// The shared card-height math behind the feed's and the thread's estimates.
/// `chrome` covers everything except the body's wrapped lines; the body wraps in
/// the 540px text column beside the 36px disc.
///
/// The line height is MEASURED, not the redesign's ratio. The mock sets the body
/// at 14.5/1.55 (22.475), but `widgetLineHeight` is `size * 1.25` with no token
/// and no per-element override anywhere in the SDK, so a body line is 18.125 here
/// and the feed reads tighter than the mock. Recorded as a wall in the plan.
fn noteRowEstimate(note: *const Note, chrome: f32) f32 {
    return noteRowEstimateWith(note, chrome, true);
}

/// The same, for a row that draws the body and NOTHING under it. A nested reply
/// is one: it builds an identity row and a body and stops, so pricing it for a
/// picture and a link card reported hundreds of pixels per reply it never drew.
fn noteRowEstimateBody(note: *const Note, chrome: f32) f32 {
    return noteRowEstimateWith(note, chrome, false);
}

fn noteRowEstimateWith(note: *const Note, chrome: f32, media: bool) f32 {
    const line_height: f32 = body_line_height;
    const chars_per_line: f32 = 70;
    // A collapsed long note shows only the fold, plus a line for "Show more".
    const collapsed = noteIsLong(note) and !isExpanded(note.id);
    const shown_chars: f32 = @floatFromInt(if (collapsed) collapsedLen(note.content(), note_collapse_chars) else note.content_len);
    const lines = @max(1, @ceil(shown_chars / chars_per_line));
    var extent = chrome + lines * line_height;
    if (collapsed) extent += line_height;
    if (!media) return extent;
    // A link card, once the page has answered; nothing before that.
    if (note.hasLink()) {
        if (linkFor(note.linkUrl())) |l| {
            if (l.state == .loaded) {
                extent += 3 + (if (l.description().len > 0) link_card_height else link_card_height_bare);
            }
        }
    }
    // A picture nobody asked for is one quiet chip, not a reserved box.
    if (note.hasImage()) {
        const shown = g_media_previews or isMediaAsked(note.id) or note.media_id() != 0;
        extent += (if (shown) pictureHeight(note) else picture_ask_height) + 8;
    }
    // The quote, which is only now a knowable height: the clamp is what makes it
    // one (the shot's own note beside 11f says quote rows clamp "so their height
    // is known at insert"). The bordered card it replaces was never priced at
    // all, so a feed of quoting notes reported less than it drew.
    // The card sits at its own byte span in the body, so a collapsed note shows
    // it only when the fold reaches past it, exactly as `noteBodyAt` decides.
    const quote_end = @as(usize, note.quote.off) + @as(usize, note.quote.len);
    const quote_shown = note.quote.kind == .event and
        (!collapsed or quote_end <= collapsedLen(note.content(), note_collapse_chars));
    if (quote_shown) {
        extent += quoteAsideExtent(note.quote.id);
    }
    return extent;
}

/// How tall a quote's aside draws: its margin, the identity block (the disc sets
/// it), and up to `quote_body_lines` lines of the quoted note. A quote still
/// resolving is priced at the skeleton it shows, so the row does not jump when
/// it lands.
fn quoteAsideExtent(id: [32]u8) f32 {
    const e = quoteFor(id) orelse return quote_quiet_chrome + quote_skeleton_height;
    return switch (e.state) {
        // The quiet states draw no identity block, so they do not carry its
        // chrome: only the 5 above, the sibling gap and the 2px pads. Pricing
        // them like the loaded aside over-charged every quoting row by nearly
        // three lines from first paint until its quote landed.
        .idle, .fetching => quote_quiet_chrome + quote_skeleton_height,
        .missing => quote_quiet_chrome + body_line_height,
        // The depth-1 pill, when the quoted note quotes something itself: it is
        // a row of its own under the body, and the row around it is priced.
        .loaded => quote_aside_chrome + quoteBodyLines(e) * body_line_height +
            (if (e.has_quote_of) quote_pill_height + 4 else 0),
    };
}

/// The lines a cached quote's body draws, counted the way the clamp cuts them.
fn quoteBodyLines(e: *const QuoteEntry) f32 {
    var lines: usize = 1;
    var column: usize = 0;
    for (e.text_buf[0..e.text_len]) |c| {
        if ((c & 0xc0) == 0x80) continue;
        if (c == '\n' or column >= ancestor_chars_per_line - 1) {
            lines += 1;
            column = 0;
            if (lines >= quote_body_lines) break;
        }
        if (c != '\n') column += 1;
    }
    return @floatFromInt(@min(lines, quote_body_lines));
}

/// One thread level's row plan: row 0 is the root note, rows 1..n the replies
/// in conversation order, with skeleton rows (first fetch still out) or the
/// quiet empty line appended. Arena-allocated per frame so the virtual list's
/// estimate callback can price unbuilt rows from model facts.
pub const ThreadRows = struct {
    /// The model, so the composer row can read the draft and the signer state.
    model: *const Model,
    root: *const Note,
    /// The chain above the focal note, oldest first, drawn as the rows before
    /// it. Empty for a thread opened at its own root.
    ancestors: []const Ancestor,
    /// Top-level replies with their own replies folded in, so ONE row is one
    /// conversation rather than one note.
    blocks: []const ThreadBlock,
    /// How many of the in-graph blocks this page shows, and how many wait behind
    /// the line. `hidden` counts CONVERSATIONS, which is the row arithmetic;
    /// `hidden_held` counts the replies inside them, which is what the line says.
    shown: usize,
    hidden: usize,
    hidden_held: usize,
    /// Replies from outside the follow graph, held below the rest. They are never
    /// dropped: the row says how many there are and opens them.
    outside: []const ThreadBlock,
    /// How many REPLIES those blocks hold, which is what the line says. A block
    /// is one conversation: its own note, the replies drawn under it, and
    /// whatever those collapse into.
    outside_held: usize,
    outside_open: bool,
    skeletons: bool,
    empty: bool,
    /// The line that says the subscription is still open. Absent in the empty
    /// state, which says it in its own words.
    footer: bool,

    /// What sits at `index`, for both the builder and the estimator. ONE function
    /// answers it, because two parallel index walks is how a row draws itself at
    /// another row's height: every earlier version of this list had the plan
    /// written out twice and had to keep the arithmetic in step by hand.
    pub const Row = union(enum) {
        ancestor: usize,
        focal,
        composer,
        block: usize,
        show_more,
        outside_line,
        outside_block: usize,
        skeleton,
        empty,
        footer,
    };

    /// The chain, then the focal note, then the reply field, then one row per
    /// shown conversation, the lines that hold what is not shown, and the footer.
    /// The field is a ROW rather than a pinned footer because the design puts it
    /// under the note being answered, where it scrolls with the conversation
    /// instead of hovering over it.
    pub fn rowAt(self: *const ThreadRows, index: usize) Row {
        if (index < self.ancestors.len) return .{ .ancestor = index };
        var i = index - self.ancestors.len;
        if (i == 0) return .focal;
        if (i == 1) return .composer;
        i -= 2;
        if (i < self.shown) return .{ .block = i };
        i -= self.shown;
        if (self.hidden > 0) {
            if (i == 0) return .show_more;
            i -= 1;
        }
        if (self.outside.len > 0) {
            if (i == 0) return .outside_line;
            i -= 1;
            if (self.outside_open) {
                if (i < self.outside.len) return .{ .outside_block = i };
                i -= self.outside.len;
            }
        }
        if (self.skeletons) {
            if (i < thread_skeleton_rows) return .skeleton;
            i -= thread_skeleton_rows;
        }
        if (self.empty) {
            if (i == 0) return .empty;
            i -= 1;
        }
        return .footer;
    }

    pub fn count(self: *const ThreadRows) usize {
        return self.ancestors.len + 2 + self.shown + @intFromBool(self.hidden > 0) +
            @intFromBool(self.outside.len > 0) + (if (self.outside_open) self.outside.len else 0) +
            (if (self.skeletons) thread_skeleton_rows else 0) + @intFromBool(self.empty) +
            @intFromBool(self.footer);
    }
};

/// How many top-level replies a page of a thread shows, and how many more each
/// press of the line reveals. No shot states a number; twenty is a long read
/// already, and the line says exactly how many are behind it.
const thread_page_size: usize = 20;
const thread_skeleton_rows: usize = 3;

/// A cheap height estimate for one thread row, sharing the feed's note math.
fn threadExtentEstimate(context: ?*const anyopaque, index: u64) f32 {
    const rows: *const ThreadRows = @ptrCast(@alignCast(context orelse return thread_reply_chrome));
    const i: usize = @intCast(index);
    return switch (rows.rowAt(i)) {
        // An ancestor: the identity block pinned to its disc, a body clamped to
        // two lines, and the rail's segment down to the next disc.
        .ancestor => |ai| blk: {
            const a = &rows.ancestors[ai];
            const lead: f32 = if (ai == 0) ancestor_top_pad else 0;
            if (a.ghost != .none) break :blk lead + ghost_row_extent;
            break :blk lead + ancestor_row_chrome + @as(f32, @floatFromInt(a.lines)) * ancestor_line_height;
        },
        // The focal note carries the identity block, its exact-time line, the
        // stats row and the verb row on top of a body set one register up. Its
        // leading space belongs to the ancestor above it when there is one.
        .focal => noteRowEstimate(rows.root, focal_row_chrome) -
            (if (rows.ancestors.len > 0) focal_leading_pad else 0),
        // The reply field: a fixed shape whatever the thread holds.
        .composer => reply_row_extent,
        // A block is its top-level reply plus the level of conversation under it,
        // so it is priced as the sum: one reply's chrome and body, then each
        // child's.
        .block => |bi| blockExtent(&rows.blocks[bi]),
        .outside_block => |oi| blockExtent(&rows.outside[oi]),
        .show_more => show_more_extent,
        .outside_line => outside_row_extent,
        .footer => listening_row_extent,
        // A skeleton or the empty line: one fixed-shape row.
        .skeleton, .empty => thread_skeleton_extent,
    };
}

/// One conversation's height: the top-level reply, then each nested child, then
/// a line for whatever the branch continues into.
fn blockExtent(block: *const ThreadBlock) f32 {
    var extent = noteRowEstimate(block.parent, thread_reply_chrome);
    for (block.children, block.deeper) |*child, deeper| {
        extent += noteRowEstimateBody(child, nested_reply_chrome) * nested_body_scale;
        if (deeper > 0) extent += branch_more_extent;
    }
    return extent;
}

/// How many lines an ancestor's clamped body wraps to: one or two, the clamp's
/// whole point.
fn ancestorBodyLines(note: *const Note) f32 {
    // No body, no line. An image-only reply is a common shape, and its content
    // is empty because the URL is lifted out of the text: pricing it at a line
    // the row never draws is space the level reports and does not fill.
    if (note.content_len == 0) return 0;
    var lines: usize = 1;
    var column: usize = 0;
    for (note.content()) |c| {
        if ((c & 0xc0) == 0x80) continue;
        if (c == '\n' or column >= ancestor_chars_per_line - 1) {
            lines += 1;
            column = 0;
            if (lines >= ancestor_body_lines) break;
        }
        if (c != '\n') column += 1;
    }
    return @floatFromInt(@min(lines, ancestor_body_lines));
}

/// One thread level's panel: header, the windowed root-and-replies list, and
/// the reply composer. Rendered for the open thread AND every ancestor still on
/// the back-stack (occluded beneath it), so each level's list stays mounted and
/// keeps its scroll offset. The list is a virtualList: only the rows in the
/// viewport are built, so a busy thread, or a stack of occluded ancestor
/// levels, stays far under the per-view widget budget (a plain scroll built
/// every reply of every level and blew straight through it). The list id is
/// the level key, so a level's scroll identity is stable as it moves between
/// current and ancestor.
fn threadPanel(ui: *AppUi, model: *const Model, root: *const Note, replies: []const Note, thread_loading: bool, level_key: u64, level: usize, occluded: bool) AppUi.Node {
    // While the first fetch is out with nothing in hand, a few skeleton rows say
    // "replies are coming"; once it has come back empty, a quiet line instead of
    // a lone root over blank space.
    const loading = replies.len == 0 and thread_loading;
    const empty = replies.len == 0 and !thread_loading;
    const rows_ctx = ui.arena.create(ThreadRows) catch return ui.column(.{}, .{});
    // Group first, then page: a page is twenty CONVERSATIONS, not twenty notes, so
    // a reply with a busy branch counts once.
    const grouped = groupThreadBlocks(ui, replies);
    // Replies from people the reader follows rank first; strangers are held below
    // one quiet line, never dropped. The partition is stable, so it preserves the
    // arrival and chronological order inside each tier.
    const split = splitByFollowGraph(ui, grouped, root.pubkey);
    const shown = @min(split.inside.len, model.thread_page[@min(level, model.thread_page.len - 1)] * thread_page_size);
    rows_ctx.* = .{
        .model = model,
        .root = root,
        .ancestors = ancestorsFor(ui, level, root, occluded),
        .blocks = split.inside,
        .shown = shown,
        .hidden = split.inside.len - shown,
        .hidden_held = heldReplies(split.inside[shown..]),
        .outside = split.outside,
        .outside_held = heldReplies(split.outside),
        .outside_open = model.thread_outside_open[@min(level, model.thread_outside_open.len - 1)],
        .skeletons = loading,
        .empty = empty,
        // The empty state says the same thing in its own words, so the footer
        // would only repeat it.
        .footer = !empty,
    };
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("thread-{d}", .{level_key}),
        .item_count = rows_ctx.count(),
        .item_extent = 0,
        .extent_estimate = threadExtentEstimate,
        .extent_context = rows_ctx,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Thread" },
    };
    const window = ui.virtualWindow(options);
    // An OCCLUDED level is behind an opaque panel: it is mounted to keep its
    // scroll offset, and nothing it builds can be seen. So it builds nothing.
    // The offset survives on the list's id and its content height, which comes
    // from the row COUNT and the estimates, not from the rows, so the walk back
    // still lands where the reader left. This is not only cheaper, it is what
    // keeps a deep back-stack inside the 1024-node ceiling: a view past it is
    // REFUSED whole, and six mounted levels of a busy thread crossed it.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = threadRowAt(ui, rows_ctx, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (occluded) ui.spacer(0) else threadHeader(ui, model),
        ui.virtualList(options, window, .{rows}),
    });
}

/// Builds the thread row at `index` (see `ThreadRows` for the plan), centred
/// like a feed row. `grow` on the wrapper is safe here: the virtual list
/// positions rows absolutely, so a growing row spreads WIDTH, exactly like the
/// feed's cards (the old plain-scroll column grew rows VERTICALLY instead,
/// which is why these wrappers were once forbidden).
fn threadRowAt(ui: *AppUi, rows_ctx: *const ThreadRows, index: usize) AppUi.Node {
    const plan = rows_ctx.rowAt(index);
    const inner = switch (plan) {
        .ancestor => |ai| ancestorRow(ui, &rows_ctx.ancestors[ai], ai == 0),
        .focal => threadRoot(ui, rows_ctx.root, rows_ctx.ancestors.len == 0),
        .composer => replyComposer(ui, rows_ctx.model, rows_ctx.root),
        // `first` draws the full-width rule under the note being answered, and
        // `last` suppresses the trailing one: a rule with nothing under it is a
        // dangling line, and its trailing space is what tips a thread that fits
        // into reporting more content than it draws. So the flags are about what
        // is ACTUALLY above and below the block, held replies included.
        .block => |bi| replyBlock(ui, &rows_ctx.blocks[bi], rows_ctx.root.pubkey, bi == 0, bi + 1 == rows_ctx.shown and rows_ctx.hidden == 0 and rows_ctx.outside.len == 0),
        .outside_block => |oi| replyBlock(ui, &rows_ctx.outside[oi], rows_ctx.root.pubkey, oi == 0 and rows_ctx.shown == 0, oi + 1 == rows_ctx.outside.len),
        .show_more => showMoreReplies(ui, rows_ctx.hidden_held),
        .outside_line => outsideGraphRow(ui, rows_ctx.outside_held, rows_ctx.outside_open),
        .footer => listeningFooter(ui),
        .empty => threadEmptyNote(ui),
        .skeleton => replySkeleton(ui),
    };
    var node = ui.row(.{ .grow = 1, .main = .center }, .{inner});
    // Stable row identity for the windowed reconciler: the note's own id, or a
    // synthetic high-bit key for the placeholder rows (their bit sits above the
    // masked 63-bit note-id space, so no collision).
    // A row with no note of its own is keyed by WHAT IT IS, not by where it sits:
    // a key folds into every descendant's identity, so keying the composer by
    // index would hand it a new identity, and drop the caret mid-typing, the
    // moment a missing ancestor resolves and every row below it shifts down.
    node.key = .{
        .int = switch (plan) {
            .focal => @intCast(rows_ctx.root.id),
            .block => |bi| @intCast(rows_ctx.blocks[bi].parent.id),
            .outside_block => |oi| @intCast(rows_ctx.outside[oi].parent.id),
            // A ghost row has no note behind it, so it takes a synthetic key like
            // the other placeholders, folding in its seat in the chain.
            .ancestor => |ai| if (rows_ctx.ancestors[ai].ghost == .none)
                @intCast(rows_ctx.ancestors[ai].note.id)
            else
                placeholderKey(@intFromEnum(std.meta.activeTag(plan)), ai),
            // Skeletons repeat, so they keep their position; every other
            // placeholder appears at most once in a level.
            .skeleton => placeholderKey(@intFromEnum(std.meta.activeTag(plan)), index),
            else => placeholderKey(@intFromEnum(std.meta.activeTag(plan)), 0),
        },
    };
    return node;
}

/// A key for a row with no note behind it: its kind, plus a discriminator for the
/// kinds that can repeat. The high bit sits above the masked 63-bit note-id
/// space, so it can never collide with a real note.
fn placeholderKey(kind: u64, nth: usize) u64 {
    return (@as(u64, 1) << 63) | (kind << 32) | @as(u64, @intCast(nth));
}

/// The open thread's replies read from the store at render time, into the arena,
/// oldest first. Used for the ANCESTOR levels (the current level reads its cached
/// `thread_notes` instead): they are occluded, so a per-frame read keeps their
/// scroll content stable without a second full reply cache. The `#e` closure
/// walk is the costly part, so its RESULT (the id set) is cached per level and
/// re-walked only when the store's event count moves; the notes themselves are
/// rebuilt into the frame arena from cheap point reads.
fn threadRepliesFromStore(ui: *AppUi, level: usize, root_event_id: [32]u8) []const Note {
    const store = g_store orelse return &.{};
    const cache = &g_level_replies[level];
    const stamp = store.eventCount() catch std.math.maxInt(usize);
    if (stamp == std.math.maxInt(usize) or cache.stamp != stamp or !std.mem.eql(u8, &cache.root, &root_event_id)) {
        cache.root = root_event_id;
        cache.stamp = stamp;
        cache.len = collectThreadIds(store, root_event_id, &cache.ids);
    }
    const now = nowSeconds();
    const notes = ui.arena.alloc(Note, cache.len) catch return &.{};
    var n: usize = 0;
    for (cache.ids[0..cache.len]) |id| {
        var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        defer se.deinit();
        notes[n] = noteFrom(se.event, now);
        n += 1;
    }
    // The SAME order the level had when it was the open thread, from the SAME
    // table: a level is mounted underneath precisely so the walk back lands where
    // the reader left it, and a second sort here would re-order the rows under an
    // offset restored for the first. This level is not fetching (its own fetch
    // finished before the reader moved on), so anything new here is genuinely
    // late and opens a batch.
    stampArrival(arrivalTableFor(level, root_event_id), notes[0..n], true);
    arrangeThread(notes[0..n], root_event_id);
    return notes[0..n];
}

/// The chain above the focal note, as rows: the ancestors in the store (oldest
/// first) with a ghost row on top when the chain does not reach the thread's
/// opening note. Built into the frame arena from the cached id list, like the
/// occluded levels' replies.
///
/// Every mounted level computes its own chain, INCLUDING the occluded ones: a
/// level's row plan has to be the same when it is beneath the current thread as
/// when it is the current thread, or its restored scroll offset would land
/// somewhere else on the way back.
fn ancestorsFor(ui: *AppUi, level: usize, focal: *const Note, occluded: bool) []const Ancestor {
    if (!focal.has_reply_parent) return &.{};
    const store = g_store orelse return &.{};
    if (level >= g_ancestor_chains.len) return &.{};
    const chain = &g_ancestor_chains[level];
    const stamp = store.eventCount() catch std.math.maxInt(usize);
    if (stamp == std.math.maxInt(usize)) return &.{};
    if (chain.stamp != stamp or !std.mem.eql(u8, &chain.focal, &focal.event_id)) {
        refreshAncestorChain(chain, store, focal, stamp);
    }

    const ghost = @intFromBool(chain.gap != .none);
    const rows = ui.arena.alloc(Ancestor, chain.len + ghost) catch return &.{};
    if (ghost == 1) rows[0] = .{ .ghost = chain.gap, .is_root = chain.gap_is_root };
    var n: usize = ghost;
    // An occluded level draws nothing, so it reads nothing: the row count and
    // the cached line counts are the whole of what its estimates need, and its
    // content height (which is what its restored scroll offset is measured
    // against) comes out identical either way.
    if (occluded) {
        for (chain.lines[0..chain.len]) |lines| {
            rows[n] = .{ .lines = lines };
            n += 1;
        }
        return rows[0..n];
    }
    const now = nowSeconds();
    for (chain.ids[0..chain.len], chain.lines[0..chain.len]) |id, lines| {
        var se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        defer se.deinit();
        rows[n] = .{ .note = noteFrom(se.event, now), .lines = lines };
        n += 1;
    }
    return rows[0..n];
}

/// The quiet line under a note that has no replies, so an empty thread reads as
/// "nothing here yet" rather than a lone post over a wall of blank space.
fn threadEmptyNote(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .main = .center }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "No replies yet. Yours would be the first.", .scale = stat_scale }}),
        }),
        vgap(ui, 12),
        // What the thread is doing about it, rather than a dead end: the
        // subscription is open and a reply will appear when one lands.
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = p.status_success, .radius = 3, .stroke_width = 0 } }, .{}),
            hgap(ui, 8),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = pluralize(ui, liveRelayCount(), "listening on {d} relay", "listening on {d} relays"), .monospace = true, .scale = mono_meta_scale }},
            ),
        }),
    });
}

/// The thread header: a Back affordance (to the parent thread, or the feed), the
/// "Thread" label, and the reply count (known from the crowd count up front, so
/// it reads right before the replies are fetched).
fn threadHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // Back names WHERE it goes, never a bare "Thread" beside the "Thread" title:
    // the feed ("Following") at the root, else the parent post's author.
    const back_label = if (model.thread_stack_len > 0)
        model.thread_stack[model.thread_stack_len - 1].author()
    else
        "Following";
    const count = model.threadReplyCount();
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 12 }, .{
            ui.el(.data_row, .{ .on_press = .close_thread, .padding = 4, .style = .{ .quiet_hover = true }, .semantics = .{ .role = .button, .label = "Back" } }, .{
                ui.row(.{ .cross = .center, .gap = 3 }, .{
                    ui.icon(.{ .width = 16, .height = 16, .style = .{ .foreground = p.text_muted } }, "chevron-left"),
                    ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_muted } }, back_label),
                }),
            }),
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Thread", .weight = .bold }}),
            // The count reads once replies are known; before then it says nothing
            // rather than a misleading "0 replies" on a note that has some.
            if (count > 0)
                ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_faint_alt } }, ui.fmt("{d} {s}", .{ count, if (count == 1) "reply" else "replies" }))
            else
                ui.spacer(0),
            ui.spacer(1),
        }),
        ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

/// A placeholder reply row shown while the first fetch is still out: a skeleton
/// avatar and lines the same shape a real reply takes, so the thread reads as
/// "loading" rather than "empty".
fn replySkeleton(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width }, .{
        ui.row(.{ .gap = 12, .cross = .start, .padding = 14 }, .{
            ui.el(.skeleton, .{ .width = avatar_size, .height = avatar_size }, .{}),
            ui.column(.{ .gap = 8, .grow = 1, .padding = 3 }, .{
                ui.el(.skeleton, .{ .width = 130, .height = 10 }, .{}),
                ui.el(.skeleton, .{ .height = 10 }, .{}),
                ui.el(.skeleton, .{ .width = 220, .height = 10 }, .{}),
            }),
        }),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
    });
}

/// The @handle for a thread identity line: the same label and the same ink rule
/// the feed's identity block uses (violet for a NIP-05, muted for a kind:0 name
/// or a short npub), or a thin skeleton while the profile is still loading, so the
/// line does not visibly fill in a beat later. `fill` grows the element to hang
/// the time to the far right (reply rows); the root note puts the handle on its
/// own line, so it does not.
fn identityHandle(ui: *AppUi, note: *const Note, fill: bool) AppUi.Node {
    const p = theme.palette;
    const label = note.handleLabel(ui.arena);
    const h = label.text;
    const ink = if (label.nip05) p.accent_identity else p.text_faint;
    if (h.len > 0) {
        return if (fill)
            ui.text(.{ .grow = 1, .style = .{ .foreground = ink } }, h)
        else
            ui.text(.{ .size = .sm, .style = .{ .foreground = ink } }, h);
    }
    // Profile still being fetched: a placeholder rather than an empty gap. Once
    // it resolves (handle or none) or we give up, this stops showing.
    if (profileLoading(note.pubkey)) {
        const bar = ui.el(.skeleton, .{ .width = 72, .height = 9 }, .{});
        return if (fill) ui.row(.{ .grow = 1, .cross = .center }, .{bar}) else bar;
    }
    return if (fill) ui.spacer(1) else ui.spacer(0);
}

/// The focused root note: the same 40px avatar and 14px inset as the feed and
/// the replies (so every row's avatar and text share one left edge), set apart
/// by a slightly larger name, the name-over-handle stack, and the composer below.
fn threadRoot(ui: *AppUi, note: *const Note, leads: bool) AppUi.Node {
    const p = theme.palette;
    const c = engagementFor(note.id);
    // A fixed-width column, centred by the scroll column's `cross = .center`. No
    // outer growing row: a `grow` child in the scroll's column grows vertically
    // and would overlap the next row. Every block inside sits 4px in, which is
    // the focal note's own inset within the reading column.
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The space above the focal note, unless an ancestor row is up there: its
        // own bottom pad is the rail's segment down to this disc, and adding both
        // would break the chain's rhythm exactly where the eye follows it.
        if (leads) vgap(ui, focal_leading_pad) else ui.spacer(0),
        // The identity line, at the disc's height, with the overflow menu at the
        // far end. No timestamp here: the focal note states its time in full
        // below, where there is room to be exact.
        ui.row(.{ .gap = 0, .cross = .center }, .{
            hgap(ui, thread_inset),
            noteAvatar(ui, note),
            hgap(ui, avatar_to_text_gap),
            identityBlock(ui, note),
            ui.spacer(1),
            // Drawn, not wired: the overflow menu (mute, report, copy link) lands
            // with the safety work. A pressable glyph that does nothing is the
            // same lie the status bar was just cured of, so it stays inert until
            // there is something behind it.
            ui.row(.{ .padding = 4 }, .{
                ui.icon(.{ .width = 15, .height = 15, .style = .{ .foreground = p.text_faint_alt } }, "ellipsis"),
            }),
            hgap(ui, thread_inset),
        }),
        vgap(ui, 9),
        // One register up from a feed row: this is the note being read.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                focalBody(ui, note),
                if (note.hasImage()) vgap(ui, 8) else ui.spacer(0),
                if (note.hasImage()) notePicture(ui, note) else ui.spacer(0),
                if (note.hasLink()) linkCard(ui, note) else ui.spacer(0),
                vgap(ui, 9),
                focalMeta(ui, note),
            }),
            hgap(ui, thread_inset),
        }),
        vgap(ui, 12),
        focalStats(ui, c),
        focalVerbs(ui, note),
    });
}

/// The focal note's body: the SAME builder every other note uses, one register up.
/// Writing a second paragraph path here cost the embedded quote card, which is
/// exactly the kind of quiet loss a parallel implementation buys.
fn focalBody(ui: *AppUi, note: *const Note) AppUi.Node {
    return noteBodyAt(ui, note, false, focal_body_scale, theme.palette.text_focal);
}

/// When the focal note was written, how widely it is held, and its nevent.
fn focalMeta(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const seen = relaysSeenFor(note.id);
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_faint_alt } },
            &.{.{
                .text = if (seen > 0)
                    ui.fmt("{s} · {s}", .{ absoluteNoteTime(ui.arena, note.created_at), pluralize(ui, seen, "seen on {d} relay", "seen on {d} relays") })
                else
                    // Nothing delivered it this session (it came off disk), so the
                    // line says when it was written and stops there.
                    absoluteNoteTime(ui.arena, note.created_at),
                .monospace = true,
                .scale = mono_hint_scale,
            }},
        ),
        ui.spacer(1),
        neventPill(ui, note),
    });
}

/// The copyable nevent: the note's own address, for sharing it anywhere.
fn neventPill(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{
        .cross = .center,
        .gap = 0,
        .on_press = Msg{ .copy_nevent = note.id },
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = "Copy nevent" },
    }, .{
        ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_chip, .border = p.border_chip, .radius = 999, .stroke_width = 1 } }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 9),
                vgap(ui, 20),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = shortNevent(ui, note), .monospace = true, .scale = mono_meta_scale }}),
                hgap(ui, 6),
                ui.icon(.{ .width = 10, .height = 10, .style = .{ .foreground = p.text_faint } }, "copy"),
                hgap(ui, 9),
            }),
        }),
    });
}

/// The focal note's tallies, as words rather than icons: the verbs below carry
/// the actions, so these are the numbers, stated plainly.
fn focalStats(ui: *AppUi, c: Counts) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset + 2),
            vgap(ui, 33),
            statCount(ui, c.replies, "reply", "replies"),
            hgap(ui, 18),
            statCount(ui, c.reposts, "repost", "reposts"),
            hgap(ui, 18),
            statCount(ui, c.likes, "like", "likes"),
            hgap(ui, 18),
            statCount(ui, c.zap_msat / 1000, "sat", "sats"),
            ui.spacer(1),
        }),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    });
}

fn statCount(ui: *AppUi, n: u64, singular: []const u8, plural: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{
        .{ .text = if (n == 0) "0" else formatCount(ui.arena, n), .weight = .medium, .color = .text, .scale = stat_scale },
        .{ .text = ui.fmt(" {s}", .{if (n == 1) singular else plural}), .scale = stat_scale },
    });
}

/// The focal note's verbs: evenly spread, no counts. The numbers are the stats row
/// above; these are the things a reader can do.
///
/// Spread by GROW spacers between the pairs, with the 40px insets as the row's own
/// padding. Two earlier shapes were wrong: an inset BOX is a flow child, so it
/// takes a share of the free space and the whole stack drifts (this measured 67px
/// of slack on the left against 28 on the right), and `main = .space_between` left
/// the stack flush against the right edge instead of balancing it.
///
/// Four verbs, not the mock's five. The fifth is Reply, whose job in the mock is
/// to reach the reply field: here that field is already on screen immediately
/// below, and the caret cannot be moved to it from the model anyway (see the round
/// plan's SDK walls). A glyph that does nothing is worse than an absent one, so it
/// returns when the composer sheet learns to open in reply mode.
fn focalVerbs(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const liked = likeEntry(note.id) != null;
    // The mock's insets are 2 above, 40 each side, 4 below, and padding on this
    // engine is ONE number for all four edges, so each axis is stated where it
    // belongs: this column carries the 2 and the 4, the row carries the 40s as
    // fixed inset boxes, and the grow spacers between the verbs take the rest.
    // Reaching for `padding = 40` to fix the sides, as the previous shape did, put
    // 40px of dead air above and below the icons too.
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 2),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 40),
            // Repost becomes a two-item menu with the repost work; inert until then.
            focalVerb(ui, "repeat", "Repost", null, p.text_verb),
            ui.spacer(1),
            focalVerb(ui, "like", if (liked) "Unlike" else "Like", Msg{ .like = note.id }, if (liked) p.status_like else p.text_verb),
            ui.spacer(1),
            // Zap waits on a wallet; it draws at rest and does nothing.
            focalVerb(ui, "zap", "Zap", null, p.text_verb),
            ui.spacer(1),
            focalVerb(ui, "external-link", "Open on the web", Msg{ .open_web = note.id }, p.text_verb),
            hgap(ui, 40),
        }),
        vgap(ui, 4),
    });
}

fn focalVerb(ui: *AppUi, glyph: []const u8, label: []const u8, press: ?Msg, tint: canvas.Color) AppUi.Node {
    return ui.row(.{
        .padding = 6,
        .cross = .center,
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = press != null },
    }, .{
        ui.appIcon(.{ .width = 17, .height = 17, .style = .{ .foreground = tint } }, glyph),
    });
}

/// One top-level reply and what hangs off it. The redesign shows exactly one
/// level of nesting in place: a reply, the replies to THAT reply, and then a line
/// saying how much of the branch continues out of sight. Deeper than that is a
/// thread of its own, which is what pressing the line opens.
pub const ThreadBlock = struct {
    parent: *const Note,
    /// The parent's direct replies, contiguous in the arranged order.
    children: []const Note,
    /// Per child, how many of ITS descendants are not drawn. Parallel to
    /// `children`, so a branch says so under the reply it continues from.
    deeper: []const usize,
};

pub fn splitByFollowGraphForTest(ui: *AppUi, blocks: []const ThreadBlock, author: [32]u8) GraphSplit {
    return splitByFollowGraph(ui, blocks, author);
}

pub fn starterPackForTest() []const [32]u8 {
    return &starter_pack;
}

/// The two tiers of a thread's replies, in their original order.
pub const GraphSplit = struct { inside: []const ThreadBlock, outside: []const ThreadBlock };

/// How many REPLIES a run of blocks holds, which is what the line above them
/// counts. A block is one conversation: the reply that opened it, the replies
/// drawn under it, and whatever those collapse into.
pub fn heldReplies(blocks: []const ThreadBlock) usize {
    var held: usize = 0;
    for (blocks) |block| {
        held += 1 + block.children.len;
        for (block.deeper) |deeper| held += deeper;
    }
    return held;
}

fn splitByFollowGraph(ui: *AppUi, blocks: []const ThreadBlock, author: [32]u8) GraphSplit {
    if (blocks.len == 0) return .{ .inside = &.{}, .outside = &.{} };
    const inside = ui.arena.alloc(ThreadBlock, blocks.len) catch return .{ .inside = blocks, .outside = &.{} };
    const outside = ui.arena.alloc(ThreadBlock, blocks.len) catch return .{ .inside = blocks, .outside = &.{} };
    var ni: usize = 0;
    var no: usize = 0;
    for (blocks) |block| {
        // The conversation is placed by whoever opened it: a stranger's reply is
        // held below even when someone followed answers inside it.
        // Whoever wrote the note being read is inside their own thread whether
        // or not the reader follows them: otherwise opening a stranger's reply
        // would hold their own continuation of it behind a collapsed line.
        if (std.mem.eql(u8, &block.parent.pubkey, &author) or inFollowGraph(block.parent.pubkey)) {
            inside[ni] = block;
            ni += 1;
        } else {
            outside[no] = block;
            no += 1;
        }
    }
    return .{ .inside = inside[0..ni], .outside = outside[0..no] };
}

/// Whether a pubkey is inside the reader's follow graph: the accounts whose
/// replies rank first in a thread. That is the live follow list, which is the
/// starter pack until following writes a contact list of its own, plus the reader.
pub fn inFollowGraph(pubkey: [32]u8) bool {
    if (activePubkey()) |me| {
        if (std.mem.eql(u8, &me, &pubkey)) return true;
    }
    for (starter_pack) |followed| {
        if (std.mem.eql(u8, &followed, &pubkey)) return true;
    }
    return false;
}

/// Groups the arranged (depth-stamped, conversation-ordered) replies into blocks.
/// The arrangement is a DFS, so a parent's subtree is contiguous: everything at
/// depth 2 until the next top-level reply is a child, and anything deeper counts
/// against the child it hangs beneath.
pub fn groupThreadBlocks(ui: *AppUi, notes: []const Note) []const ThreadBlock {
    if (notes.len == 0) return &.{};
    const blocks = ui.arena.alloc(ThreadBlock, notes.len) catch return &.{};
    const deeper_pool = ui.arena.alloc(usize, notes.len) catch return &.{};
    var block_count: usize = 0;
    var pool_used: usize = 0;
    var i: usize = 0;
    while (i < notes.len) {
        const parent = &notes[i];
        i += 1;
        const child_start = i;
        var child_count: usize = 0;
        while (i < notes.len and notes[i].depth >= 2) {
            if (notes[i].depth == 2) {
                deeper_pool[pool_used + child_count] = 0;
                child_count += 1;
            } else if (child_count > 0) {
                // Deeper than the one level shown: counted against the child whose
                // branch it continues.
                deeper_pool[pool_used + child_count - 1] += 1;
            }
            i += 1;
        }
        blocks[block_count] = .{
            .parent = parent,
            .children = notes[child_start..][0..child_count],
            .deeper = deeper_pool[pool_used..][0..child_count],
        };
        block_count += 1;
        pool_used += child_count;
    }
    return blocks[0..block_count];
}

/// How many indent steps a reply at `depth` shows. Direct replies (depth 1)
/// sit flush; each further level steps in once, capped so a long back-and-forth
/// never squeezes the text to a sliver; past the cap, deeper replies share the
/// cap's inset (the convention every threaded reader settles on).
const thread_indent_cap = 3;
const thread_indent_step: f32 = 24;

pub fn threadIndentLevels(depth: u8) usize {
    if (depth <= 1) return 0;
    return @min(@as(usize, depth - 1), thread_indent_cap);
}

/// The nesting gutter to the left of an indented reply: one fixed-width cell
/// per ancestor level, each carrying a hairline rail, so siblings at a depth
/// visibly hang off the same line. Empty (and costless) at the top level.
fn threadGutter(ui: *AppUi, levels: usize) AppUi.Node {
    if (levels == 0) return ui.spacer(0);
    const p = theme.palette;
    const cells = ui.arena.alloc(AppUi.Node, levels) catch return ui.spacer(0);
    for (cells) |*cell| {
        // The rail fills the row's height on its own via cross-axis stretch.
        cell.* = ui.row(.{ .width = thread_indent_step, .main = .center }, .{
            ui.separator(.{ .width = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
        });
    }
    return ui.row(.{}, .{cells});
}

/// One reply in the thread: a feed-style row, with an "OP" chip when the
/// replier is the thread's original author, seated under the note it answers by
/// the nesting gutter. The WRAPPER row carries the press and the hover wash, so
/// every horizontal pixel of the row (gutter included) opens this reply as
/// its own thread and washes as one unit; the picture and the engagement
/// controls keep their own presses as the deeper hit targets. The bottom
/// hairline lives INSIDE the content column: it starts after the gutter (so it
/// aligns with the content it separates) and the gutter's rails span the
/// wrapper's full height across it, keeping a sibling run's rail continuous.
/// One top-level reply and the level of conversation under it. The block draws
/// the reply at note size against a rail, then each of its own replies at a
/// smaller register hanging off that rail, then a line for whatever the branch
/// continues into.
///
/// The rail replaces the round-4 indent gutter: the redesign nests ONE level in
/// place and sends the rest to their own thread, rather than stepping every reply
/// further right until the text runs out of room.
fn replyBlock(ui: *AppUi, block: *const ThreadBlock, root_author: [32]u8, first: bool, last: bool) AppUi.Node {
    const p = theme.palette;
    const note = block.parent;
    const kids = ui.arena.alloc(AppUi.Node, block.children.len * 2) catch return ui.spacer(0);
    var n: usize = 0;
    for (block.children, block.deeper) |*child, deeper| {
        kids[n] = nestedReply(ui, child, root_author);
        n += 1;
        if (deeper > 0) {
            kids[n] = branchMore(ui, child, deeper);
            n += 1;
        }
    }

    var node = ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The first block takes the full-width rule that separates the replies
        // from the note they answer; between blocks the rule is inset to the text,
        // so the rails run unbroken down the gutter.
        if (first)
            ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } })
        else
            ui.spacer(0),
        vgap(ui, 12),
        // No `cross` here: the default stretches the children, which is what
        // gives the rail a height to grow into. Pinned to the top, the disc's
        // column would be exactly as tall as the disc and the rail would draw
        // nothing at all, which is how it shipped invisible.
        // The reply's OWN row, and only it: the wash belongs to the row under the
        // pointer, and a band covering this reply plus everything nested under it
        // is one highlight over three rows.
        ui.el(.data_row, .{
            .width = thread_column_width,
            .padding = 0.01,
            .on_press = Msg{ .open_thread = note.id },
            .semantics = .{ .label = "Open thread" },
        }, .{
            hgap(ui, thread_inset),
            // The disc, with the rail below it: the line a reply's own replies
            // hang from. It runs to the bottom of this row and the children's
            // section picks it up from there, so the line reads as one.
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                noteAvatar(ui, note),
                vgap(ui, 4),
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .start }, .{
                    identityBlock(ui, note),
                    ui.spacer(1),
                    ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_faint_alt } }, note.time()),
                }),
                vgap(ui, 5),
                noteBody(ui, note, true),
                if (note.hasImage()) vgap(ui, 8) else ui.spacer(0),
                if (note.hasImage()) notePicture(ui, note) else ui.spacer(0),
                if (note.hasLink()) linkCard(ui, note) else ui.spacer(0),
                vgap(ui, 8),
                engagementRow(ui, note),
            }),
            hgap(ui, thread_inset),
        }),
        // What hangs off this reply: its own replies and the line into whatever
        // the branch continues into, in the same gutter so the rail runs on.
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.row(.{ .width = avatar_size, .main = .center }, .{
                ui.separator(.{ .width = 2, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.column(.{ .gap = 0 }, .{kids[0..n]}),
                vgap(ui, if (last) 4 else 12),
                // The rule between blocks starts at the text, not the window edge,
                // so the rail crosses it without a break. The last block draws
                // none: a rule with nothing under it is a dangling line, and its
                // trailing space is what tips a thread that fits into reporting
                // more content than it draws.
                if (last)
                    ui.spacer(0)
                else
                    ui.separator(.{ .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
            }),
            hgap(ui, thread_inset),
        }),
    });
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// One note in the chain above the focal note: the same disc and identity block
/// as a reply, a body clamped to two lines, and the rail running down to the next
/// disc. Pressing it focuses that note, which is how a reader walks back up a
/// conversation without leaving the thread.
///
/// The chain is drawn INLINE rather than as the stack of panels it used to be:
/// one scroll, so the ancestors read as the run-up to the note being read instead
/// of as screens behind it. The panel stack stays mounted underneath purely to
/// hold each level's scroll offset for the walk back.
fn ancestorRow(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    if (ancestor.ghost != .none) return ghostRow(ui, ancestor, first);
    const p = theme.palette;
    const note = &ancestor.note;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        if (first) vgap(ui, ancestor_top_pad) else ui.spacer(0),
        // The row stretches its children (the default cross alignment), which is
        // what gives the rail a height to grow into: pinned to the top instead,
        // the avatar column would be exactly as tall as the disc and the rail
        // would draw nothing.
        // A `list_item`, which is the kind the renderer washes on hover, given an
        // explicit width so it constrains the body instead of sizing to it.
        ui.el(.data_row, .{
            .width = thread_column_width,
            .padding = 0.01,
            // By EVENT id: an ancestor is neither in the feed nor in the open
            // thread's replies, so the render key `open_thread` resolves through
            // would find nothing and the press would quietly do nothing.
            .on_press = Msg{ .open_event = note.event_id },
            .semantics = .{ .role = .button, .label = "Focus this note" },
        }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                noteAvatar(ui, note),
                vgap(ui, 4),
                // The rail, filling whatever is left of the row: the line that
                // ties this note to the one it leads to.
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .start }, .{
                    identityBlock(ui, note),
                    ui.spacer(1),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, &.{.{ .text = note.time(), .scale = meta_scale }}),
                }),
                // The gap stays whatever the body is: it is a term of the row's
                // chrome, and dropping it would make the estimate wrong by 4px
                // for exactly the rows nothing measures.
                vgap(ui, ancestor_identity_gap),
                if (note.content_len == 0) ui.spacer(0) else ancestorBody(ui, note),
                vgap(ui, ancestor_bottom_pad),
            }),
            hgap(ui, thread_inset),
        }),
    });
}

/// An ancestor's body, cut to two lines. The SDK has no multi-line clamp, so the
/// cut is made in the SPANS: building them from the whole text first keeps a
/// mention reading as `@name` rather than as half of a bech32 token.
fn ancestorBody(ui: *AppUi, note: *const Note) AppUi.Node {
    const spans = clampSpansToLines(ui, contentSpans(ui, note.content()), ancestor_body_lines);
    return textParaAt(ui, spans, nested_body_scale, theme.palette.text_secondary_alt);
}

/// `spans` cut to at most `lines` lines, with an ellipsis where the cut falls.
///
/// Lines are counted the way the estimator counts them, by characters against a
/// column width, plus every newline the text writes for itself: a note that
/// breaks its own lines is the case a character budget alone gets wrong, and it
/// is a common shape (a note that ends in a `nostr:` reference on its own line).
fn clampSpansToLines(ui: *AppUi, spans: []const canvas.TextSpan, lines: usize) []const canvas.TextSpan {
    const out = ui.arena.alloc(canvas.TextSpan, spans.len) catch return spans;
    // One column of the last line belongs to the ellipsis. Cutting at the full
    // budget and THEN appending it wrapped one character onto a third line,
    // which is a line the estimator does not price and the design does not have.
    const budget = ancestor_chars_per_line - 1;
    var n: usize = 0;
    var line: usize = 1;
    var column: usize = 0;
    for (spans) |span| {
        var cut: ?usize = null;
        for (span.text, 0..) |c, i| {
            // A continuation byte is the middle of a character, not another one.
            if ((c & 0xc0) == 0x80) continue;
            if (c == '\n' or column >= budget) {
                line += 1;
                column = 0;
                if (line > lines) {
                    cut = i;
                    break;
                }
            }
            if (c != '\n') column += 1;
        }
        if (cut) |at| {
            // Back off to a word boundary, so the ellipsis follows a whole word.
            // The budget is the WHOLE span, not `at`: `collapsedLen` returns the
            // length unchanged when the text already fits, so cutting a slice at
            // its own length backs off nowhere.
            const end = collapsedLen(span.text, at);
            if (end > 0) {
                out[n] = span;
                out[n].text = ui.fmt("{s}…", .{std.mem.trimEnd(u8, span.text[0..end], " \n")});
                n += 1;
            } else if (n > 0) {
                out[n - 1].text = ui.fmt("{s}…", .{std.mem.trimEnd(u8, out[n - 1].text, " \n")});
            }
            return out[0..n];
        }
        out[n] = span;
        n += 1;
    }
    return out[0..n];
}

/// The ancestor row and one reply block, for a test that asserts what they PAINT
/// (the rail between two discs is a grown separator, so it only exists when the
/// row hands its avatar column a height, which is exactly what once went wrong).
pub fn ancestorRowForTest(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    return ancestorRow(ui, ancestor, first);
}

pub fn replyBlockForTest(ui: *AppUi, block: *const ThreadBlock, root_author: [32]u8, first: bool, last: bool) AppUi.Node {
    return replyBlock(ui, block, root_author, first, last);
}

/// The rows a level can hold whose height is a fixed constant, so a test can
/// measure each one and hold its estimate to what it actually draws. Every
/// constant here was hand-calibrated once and then drifted.
pub fn ghostRowForTest(ui: *AppUi, capped: bool) AppUi.Node {
    const ancestor: Ancestor = .{ .ghost = if (capped) .capped else .missing };
    return ghostRow(ui, &ancestor, true);
}

pub fn listeningFooterForTest(ui: *AppUi) AppUi.Node {
    return listeningFooter(ui);
}

pub fn outsideGraphRowForTest(ui: *AppUi, open: bool) AppUi.Node {
    return outsideGraphRow(ui, 2, open);
}

pub fn showMoreRepliesForTest(ui: *AppUi) AppUi.Node {
    return showMoreReplies(ui, 3);
}

pub const ghost_row_extent_for_test = ghost_row_extent;
pub const listening_row_extent_for_test = listening_row_extent;
pub const outside_row_extent_for_test = outside_row_extent;
pub const show_more_extent_for_test = show_more_extent;
pub const ancestor_row_chrome_for_test = ancestor_row_chrome;

pub fn ancestorBodyLinesForTest(note: *const Note) f32 {
    return ancestorBodyLines(note);
}

/// The gap at the top of the chain: a dashed seat where a note would be, saying
/// what is missing and what the app is doing about it. Never a spinner over the
/// thread, and never a claim that the note does not exist.
fn ghostRow(ui: *AppUi, ancestor: *const Ancestor, first: bool) AppUi.Node {
    const p = theme.palette;
    const capped = ancestor.ghost == .capped;
    const headline: []const u8 = if (capped)
        "Earlier notes in this thread are not shown"
    else if (ancestor.is_root)
        "Root note not on your relays yet"
    else
        "The note this answers is not on your relays yet";
    const detail: []const u8 = if (capped)
        ui.fmt("showing the {d} nearest below", .{thread_ancestor_max})
    else
        pluralize(ui, liveRelayCount(), "asking {d} relay · fills in when one answers", "asking {d} relays · fills in when one answers");
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        if (first) vgap(ui, ancestor_top_pad) else ui.spacer(0),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.column(.{ .cross = .center, .gap = 0 }, .{
                // The empty seat: the canvas has no dashed strokes, so the ring is
                // an icon with its dashes baked into the geometry, with the glyph
                // stacked over it.
                ui.stack(.{ .width = avatar_size, .height = avatar_size }, .{
                    ui.appIcon(.{ .width = avatar_size, .height = avatar_size, .style = .{ .foreground = p.border_dashed } }, "dashed-ring"),
                    ui.column(.{ .width = avatar_size, .height = avatar_size, .main = .center, .cross = .center }, .{
                        // A runtime choice of glyph, so `appIcon` (which resolves
                        // the built-in names too) rather than comptime `icon`.
                        ui.appIcon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.text_dim } }, if (capped) "chevron-up" else "clock"),
                    }),
                }),
                vgap(ui, 4),
                ui.separator(.{ .width = 2, .grow = 1, .style = .{ .foreground = p.border_hairline, .background = p.border_hairline } }),
            }),
            hgap(ui, avatar_to_text_gap),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 2),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = headline, .scale = nested_name_scale }}),
                vgap(ui, 3),
                ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = detail, .monospace = true, .scale = mono_meta_scale }}),
                vgap(ui, ancestor_bottom_pad),
            }),
            hgap(ui, thread_inset),
        }),
    });
}

/// The line at the foot of a thread: the subscription is still open, and what
/// arrives is appended rather than shuffled into what has already been read,
/// which is the promise the reply order keeps.
fn listeningFooter(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const live = liveRelayCount();
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        // The last conversation above closes at 4px (it draws no rule of its
        // own, so nothing dangles), and this makes up the rest of the step.
        vgap(ui, 8),
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_row, .background = p.divider_row } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = if (live > 0) p.status_success else p.status_offline, .radius = 3, .stroke_width = 0 } }, .{}),
            hgap(ui, 8),
            ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{
                .text = if (live > 0)
                    "listening · new replies land as relays answer, appended, never reordered"
                else
                    "no relay connected · replies land when one answers",
                .monospace = true,
                .scale = mono_meta_scale,
            }}),
        }),
        vgap(ui, 10),
    });
}

/// A reply to a reply: the one level of nesting the redesign draws in place, at a
/// smaller disc and a smaller register than the reply it answers.
fn nestedReply(ui: *AppUi, note: *const Note, root_author: [32]u8) AppUi.Node {
    const p = theme.palette;
    const is_author = std.mem.eql(u8, &note.pubkey, &root_author);
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.el(.data_row, .{
            .grow = 1,
            .padding = 0.01,
            .cross = .start,
            .on_press = Msg{ .open_thread = note.id },
            .semantics = .{ .label = "Open thread" },
        }, .{
            avatarDisc(ui, note, nested_avatar_size),
            hgap(ui, 10),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                ui.row(.{ .gap = 6, .cross = .center }, .{
                    ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = note.author(), .weight = .medium, .scale = nested_name_scale }}),
                    // The original poster, marked in their own thread. In the
                    // author's avatar tint, so the chip reads as them.
                    if (is_author) opChip(ui, note.pubkey) else ui.spacer(0),
                    if (note.verified())
                        ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle")
                    else
                        ui.spacer(0),
                    nestedHandle(ui, note),
                    ui.spacer(1),
                    ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, &.{.{ .text = note.time(), .scale = nested_meta_scale }}),
                }),
                vgap(ui, 3),
                noteBodyAt(ui, note, true, nested_body_scale, p.text_nested),
            }),
        }),
    });
}

/// The OP chip: the thread's author, marked where they answer inside it.
fn opChip(ui: *AppUi, pubkey: [32]u8) AppUi.Node {
    const tint = avatarTint(pubkey);
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = tint.bg, .border = tint.border, .radius = 4, .stroke_width = 1 } }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 5),
            ui.paragraph(.{ .style = .{ .foreground = tint.glyph } }, &.{.{ .text = "OP", .weight = .medium, .monospace = true, .scale = op_chip_scale }}),
            hgap(ui, 5),
        }),
    });
}

/// A nested reply's handle, one register below the reply it answers.
fn nestedHandle(ui: *AppUi, note: *const Note) AppUi.Node {
    const handle = note.handle(ui.arena);
    if (handle.len == 0) return ui.spacer(0);
    return ui.paragraph(
        .{ .style = .{ .foreground = theme.palette.accent_identity } },
        &.{.{ .text = handle, .scale = nested_meta_scale }},
    );
}

/// The line that holds the strangers: how many replies came from outside the
/// follow graph, and a press that shows them. They are never deleted, only held,
/// which is what the line says.
fn outsideGraphRow(ui: *AppUi, count: usize, open: bool) AppUi.Node {
    const p = theme.palette;
    // The row's own padding sits INSIDE it, so the wash covers the band the shot
    // pads rather than a stripe through the middle of it. The height is stated
    // because a `list_item` carries a 28px intrinsic row floor, and this line is
    // a single 18px text line: without it the quiet line grows ten pixels looser
    // than the shot.
    return ui.el(
        .data_row,
        .{
            .width = thread_column_width,
            .height = outside_row_extent,
            .padding = 0.01,
            .cross = .center,
            .on_press = .toggle_outside_replies,
            // The row is a disclosure, so it says which way it is pointing: the
            // glyph, the verb in the label, and the accessible expanded state.
            .expanded = open,
            .semantics = .{ .role = .button, .label = if (open) "Hide replies from outside your graph" else "Show replies from outside your graph", .focusable = true },
        },
        .{
            hgap(ui, 52),
            // The glyph is chosen at runtime, so `appIcon` (which resolves the
            // built-in names too) rather than the comptime-checked `icon`.
            ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_dim } }, if (open) "chevron-up" else "eye"),
            hgap(ui, 7),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = pluralize(ui, count, "{d} reply from outside your graph", "{d} replies from outside your graph"), .scale = meta_scale }},
            ),
            hgap(ui, 7),
            // What the line is doing right now: holding them, or having shown
            // them. Saying "held below" under replies that are on screen would
            // be the same kind of stale label the round keeps finding.
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = if (open) "shown, below your graph" else "held below, never deleted", .monospace = true, .scale = mono_meta_scale }},
            ),
        },
    );
}

/// The line under a page of replies: how many conversations are still folded, and
/// a press that reveals the next page.
fn showMoreReplies(ui: *AppUi, hidden: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        vgap(ui, 12),
        // Height stated for the same reason as the held line: a `list_item` (the
        // kind that washes) carries a 28px intrinsic floor.
        ui.el(.data_row, .{
            .width = thread_column_width,
            .height = show_more_extent - 12 - 10,
            .padding = 0.01,
            .cross = .center,
            .on_press = .show_more_replies,
            .semantics = .{ .role = .button, .label = "Show more replies", .focusable = true },
        }, .{
            hgap(ui, 52),
            ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_muted } }, "chevron-down"),
            hgap(ui, 7),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = pluralize(ui, hidden, "Show {d} more reply", "Show {d} more replies"), .weight = .medium, .scale = stat_scale }},
            ),
        }),
        vgap(ui, 10),
    });
}

/// What a branch continues into: how many replies hang below the level shown, and
/// a press that opens that reply as its own thread, where they all fit.
fn branchMore(ui: *AppUi, child: *const Note, deeper: usize) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 6),
        ui.el(.data_row, .{
            .grow = 1,
            .height = branch_more_extent - 6,
            .padding = 0.01,
            .cross = .center,
            .on_press = Msg{ .open_thread = child.id },
            .semantics = .{ .role = .button, .label = "More in this branch", .focusable = true },
        }, .{
            // Indented to the nested rail, so the line reads as part of the branch
            // it belongs to.
            hgap(ui, nested_avatar_size + 10),
            ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_muted } }, "arrow-right"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_secondary } },
                &.{.{ .text = ui.fmt("More in this branch · {d}", .{deeper}), .weight = .medium, .scale = stat_scale }},
            ),
        }),
    });
}

/// The pinned reply composer at the bottom of a thread: type a reply and send it
/// to the root note. Pre-filled with whom you are answering.
fn replyComposer(ui: *AppUi, model: *const Model, root: *const Note) AppUi.Node {
    const p = theme.palette;
    const ready = !model.reply_empty();
    return ui.column(.{ .width = thread_column_width, .gap = 0 }, .{
        ui.separator(.{ .width = thread_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        vgap(ui, 10),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, thread_inset),
            meAvatar(ui, avatar_size),
            hgap(ui, avatar_to_text_gap),
            // The field IS the pill. A text_field paints its own surface, so
            // wrapping one in a rounded panel drew a rectangle inside a capsule:
            // the shape belongs on the control itself.
            ui.el(.text_field, .{
                .grow = 1,
                .height = 34,
                .padding = 14,
                .text = model.reply_draft(),
                // By handle, as the shot addresses them: a reply is to an account,
                // and the name above already said who that is.
                .placeholder = ui.fmt("Reply to {s}…", .{replyTarget(ui, root)}),
                .on_input = AppUi.inputMsg(.reply_edit),
                .on_submit = .reply_submit,
                .style = .{ .background = p.surface_input, .border = p.border_chip, .radius = 999, .stroke_width = 1 },
            }, .{}),
            hgap(ui, 10),
            // The verb sits beside the field, quiet until there is something to
            // send: an empty reply has nothing to confirm.
            ui.row(.{
                .cross = .center,
                .gap = 0,
                .on_press = if (ready) Msg.reply_submit else null,
                .style = .{ .quiet_hover = true },
                .semantics = .{ .role = .button, .label = "Reply", .focusable = ready },
            }, .{
                ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = if (ready) p.accent else p.surface_rail_tile, .radius = 8, .stroke_width = 0 } }, .{
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 14),
                        vgap(ui, 30),
                        ui.paragraph(
                            .{ .style = .{ .foreground = if (ready) p.on_accent else p.text_muted } },
                            &.{.{ .text = "Reply", .weight = .medium, .scale = stat_scale }},
                        ),
                        hgap(ui, 14),
                    }),
                }),
            }),
            hgap(ui, thread_inset),
        }),
        vgap(ui, 10),
    });
}

/// The feed screen: the rail, then the content, the feed, with a thread layered
/// over it when one is open.
/// Wraps a thread level's panel in a full-bleed opaque panel that occludes
/// whatever is beneath it (a bare column does not reliably paint its background;
/// the `.card` element does). Keyed by the level's root id so the whole level
/// keeps its identity, and its scroll offset, as levels push and pop above it.
fn threadOccluder(ui: *AppUi, level_key: u64, panel: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    // A bare `.card` injects the house 24px content padding whenever `padding`
    // is left at zero (zero IS the unset sentinel), which framed the whole
    // thread page in a margin the feed does not have. A hair above zero opts
    // out while staying invisibly small, so the thread sits flush like the feed.
    return ui.el(.card, .{ .grow = 1, .padding = 0.01, .global_key = .{ .int = level_key }, .style = .{ .background = p.surface_window, .border = p.surface_window, .radius = 0, .stroke_width = 0 } }, .{panel});
}

/// A stable, collision-free scroll identity for a thread level: the level index
/// in the high bits (distinct per position, so an ancestor keeps its key and
/// offset while deeper levels push and pop, and two levels never collide even if
/// the same note appears twice) and the root note id in the low bits (so when
/// the stack is saturated at `thread_depth_max` and `enterThread` replaces the
/// top root in place, the new level gets a fresh key and opens at the top rather
/// than inheriting the dropped thread's offset).
fn threadLevelKey(level: usize, root_id: i64) u64 {
    const hi = @as(u64, level) << 59;
    const lo = @as(u64, @intCast(root_id)) & ((@as(u64, 1) << 59) - 1);
    return hi | lo;
}

fn feedView(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // The feed is always built (so it is always mounted): a thread is layered
    // OVER it, not swapped in, so the feed's scroll offset survives and closing
    // a thread returns the reader to where they were, not the top. EACH open
    // thread level is layered too (occluded ancestors under the current one), so
    // every level keeps its own scroll offset and Back never lands a parent
    // thread at the top.
    const feed = feedContent(ui, model);
    const content = if (model.viewing_thread != 0) blk: {
        // feed + one panel per level: the back-stacked ancestors (oldest first),
        // then the current thread on top.
        const kids = ui.arena.alloc(AppUi.Node, 2 + model.thread_stack_len) catch break :blk feed;
        kids[0] = feed;
        for (0..model.thread_stack_len) |d| {
            const root = &model.thread_stack[d];
            const lk = threadLevelKey(d, root.id);
            kids[1 + d] = threadOccluder(ui, lk, threadPanel(ui, model, root, threadRepliesFromStore(ui, d, root.event_id), false, lk, d, true));
        }
        const lk = threadLevelKey(model.thread_stack_len, model.thread_root.id);
        kids[kids.len - 1] = threadOccluder(ui, lk, threadPanel(ui, model, &model.thread_root, model.thread_notes[0..model.thread_notes_len], model.thread_loading, lk, model.thread_stack_len, false));
        break :blk ui.stack(.{ .grow = 1 }, .{kids});
    } else feed;

    // The window is the rail plus the content. The old titlebar of buttons is
    // gone: home, compose, settings, and the account seat live on the rail, so
    // the feed owns the full width below the OS titlebar.
    return ui.row(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        railView(ui, model),
        // A 1px vertical rule between the rail and the content. No `grow`: in a
        // row that would stretch it along the WIDTH and eat the feed's space; it
        // fills the height on its own via the row's cross-axis stretch.
        ui.separator(.{ .width = 1, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        content,
    });
}

/// The feed content column: the guest banner, the scope line, the note list, and
/// the status bar.
fn feedContent(ui: *AppUi, model: *const Model) AppUi.Node {
    // The data-window seam: the runtime resolves scroll offset and viewport
    // into a visible index range, and only those rows are built. A feed of any
    // length then costs what the handful on screen costs.
    const options = feedOptions(model);
    const window = ui.virtualWindow(options);
    const rows = ui.arena.alloc(AppUi.Node, window.itemCount()) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    for (rows, 0..) |*row, offset| row.* = noteCard(ui, &model.notes[window.start_index + offset]);

    // Exactly which rows are on screen, which is what decides where the image
    // budget goes. Recorded here because the runtime resolves it during the
    // build, while the fetch pass runs later, in `update`.
    g_visible_first = window.first_visible_index;
    g_visible_last = window.last_visible_index;

    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        if (model.show_guest_strip()) guestBanner(ui, model) else ui.spacer(0),
        // Under the guest strip, because being signed out is the bigger fact.
        offlineBanner(ui, model),
        scopeHeader(ui, model),
        if (model.notes_len == 0)
            ui.column(.{ .gap = 12, .main = .center, .cross = .center, .grow = 1, .padding = 24 }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, model.empty_text()),
            })
        else
            // The list owns its scroll state, keyed by the id in `feedOptions`,
            // so the offset survives every rebuild (and the image viewer
            // opening over it) without the model mirroring it.
            ui.virtualList(options, window, .{rows}),
        if (model.backup_nudge) backupNudge(ui) else ui.spacer(0),
        statusBar(ui, model),
    });
}

/// The 56px navigation rail: Home (the mark) up top, then the compose verb, the
/// Settings gear, and the "you" seat pinned to the bottom. This replaces the old
/// titlebar of buttons: destinations on the edge, the feed owns the width. A
/// guest's gated tiles (compose, settings, you) route to the join sheet. Search
/// is not shown until the feature exists.
fn railView(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const guest = model.is_guest();
    const compose_press: Msg = if (guest) .open_join else .open_compose;
    const settings_press: Msg = if (guest) .open_join else .open_settings;
    // Gap 0 with explicit steps: the rail insets are 10 above and 12 below, which
    // one uniform padding cannot state. The 10 on each side is exactly what
    // centring a 36px tile in the 56px rail leaves, so it stays as padding.
    return ui.column(.{ .width = 56, .cross = .center, .gap = 0, .padding = 10, .style_tokens = .{ .background = .background } }, .{
        // Home: the mark on a raised plate, the active destination.
        tilePlate(ui, .{ .background = p.surface_rail_tile, .border = p.border_hairline, .radius = 9, .stroke_width = 1 }, "Home", ui.appIcon(.{ .width = 21, .height = 21, .style = .{ .foreground = p.text_primary } }, "mark")),
        // The bottom cluster hangs off the floor of the rail: verbs, then meta.
        ui.spacer(1),
        // Compose: the one bright tile.
        railTile(ui, "edit", 15, compose_press, "New note", true),
        vgap(ui, rail_gap),
        // Settings.
        railTile(ui, "settings", 16, settings_press, "Settings", false),
        vgap(ui, rail_gap),
        // The account seat: a dashed "you" as a guest, the account once signed in.
        railYou(ui, guest),
        vgap(ui, 2),
    });
}

/// A 36px rail plate with one centered glyph.
///
/// The plate is a `.panel`, not a styled column. The renderer draws NOTHING for
/// the layout kinds (stack, row, column and friends), which is why every rail tile
/// had been painting as bare window, the bright compose tile included. A `.card`
/// paints but carries a 240x120 intrinsic size that blew the rail apart; `.panel`
/// paints AND sizes to its children. It layers its children, so the sizing column
/// inside does the centring, and the 0.01 padding is belt and braces: the house
/// padding substitution only reaches kinds that declare a default layout, which a
/// panel does not, so the plate sits flush either way.
fn tilePlate(ui: *AppUi, style: canvas.WidgetStyle, label: []const u8, glyph: AppUi.Node) AppUi.Node {
    // An empty label leaves the plate anonymous, which is what a plate inside a
    // named pressable row wants: two nodes with one name read as two controls.
    // The unpressed Home plate passes its own name, since nothing else carries it.
    return ui.el(.panel, .{ .padding = 0.01, .style = style, .semantics = .{ .label = label } }, .{
        ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// One pressable rail tile: a 36px plate with a centered icon. `bright` paints
/// the accent fill (the compose verb); the rest are quiet with a muted glyph.
fn railTile(ui: *AppUi, comptime icon: []const u8, size: f32, press: Msg, label: []const u8, bright: bool) AppUi.Node {
    const p = theme.palette;
    const tint = if (bright) p.on_accent else p.text_muted;
    const glyph = ui.icon(.{ .width = size, .height = size, .style = .{ .foreground = tint } }, icon);
    return ui.row(.{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        // Only the compose tile carries a plate. The quiet tiles are a glyph on
        // the rail itself, so they take no panel at all: a panel with no stated
        // background falls back to the house card fill and would draw a plate the
        // redesign does not have.
        if (bright)
            tilePlate(ui, .{ .background = p.accent, .radius = 9, .stroke_width = 0 }, "", glyph)
        else
            ui.column(.{ .width = 36, .height = 36, .main = .center, .cross = .center }, .{glyph}),
    });
}

/// The account seat at the bottom of the rail. A guest gets a dashed circle
/// marked "you" that opens the join sheet; a signed-in user gets a small tinted
/// initials avatar that opens Settings.
fn railYou(ui: *AppUi, guest: bool) AppUi.Node {
    const p = theme.palette;
    const press: Msg = if (guest) .open_join else .open_settings;
    return ui.el(.data_row, .{
        .on_press = press,
        .padding = 0,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .label = "You" },
    }, .{
        if (guest)
            // The seat reads as an outline waiting to be filled, so its ring is
            // dashed. The canvas has no dashed strokes, so the ring is an icon
            // whose dashes are baked into its geometry, with the label stacked
            // over it.
            ui.stack(.{ .width = 28, .height = 28 }, .{
                ui.appIcon(.{ .width = 28, .height = 28, .style = .{ .foreground = p.border_dashed } }, "dashed-ring"),
                ui.column(.{ .width = 28, .height = 28, .main = .center, .cross = .center }, .{
                    ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = "you", .monospace = true, .scale = 8.5 / 14.5 }}),
                }),
            })
        else
            youAvatar(ui),
    });
}

/// The signed-in account avatar for the rail: a 28px tinted circle with the
/// pubkey's initials (the same warm tint the feed uses for that key).
fn youAvatar(ui: *AppUi) AppUi.Node {
    return meAvatar(ui, 28);
}

/// The signed-in reader's own disc at a stated size: the rail seats a 28, the
/// thread's reply row a 36 to match the note it answers.
fn meAvatar(ui: *AppUi, size: f32) AppUi.Node {
    const pk = activePubkey() orelse return ui.spacer(0);
    const tint = avatarTint(pk);
    const hexdigits = "0123456789abcdef";
    return ui.avatar(.{
        .width = size,
        .height = size,
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
    }, ui.fmt("{c}{c}", .{ hexdigits[pk[0] >> 4], hexdigits[pk[0] & 0x0f] }));
}

/// The backup nudge: calm, dismissible, the stakes stated plainly. Rises once,
/// after the first local-key post of a session.
fn backupNudge(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .style = .{ .background = p.surface_subbar } }, .{
        ui.column(.{ .height = 1, .style = .{ .background = p.divider_chrome } }, .{}),
        ui.row(.{ .cross = .center, .gap = 10, .padding = 10 }, .{
            ui.text(
                .{ .size = .sm, .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                "Right now this key lives on one Mac. Back it up so losing the Mac is not losing the account.",
            ),
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = .backup_now }, "Back up"),
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .backup_later }, "Not now"),
        }),
    });
}

/// The guest banner: a full-width top bar over the feed with the invitation and
/// the two join CTAs, always present here so sign-in is never more than one bar
/// away. Dismissible, and safely so: the rail's compose and account tiles and
/// the status bar's Guest chip all keep a way in after it is closed.
fn guestBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    _ = model;
    const p = theme.palette;
    // On a `.panel`, not a column: a column paints no background at all, so the
    // banner had been reading as plain window behind its own copy.
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_subbar, .stroke_width = 0, .radius = 0 } }, .{
        ui.column(.{ .gap = 0 }, .{
            vgap(ui, 8),
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, chrome_inset),
                ui.paragraph(
                    .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_muted_alt } },
                    &.{.{ .text = "Browsing as a guest. Reading is yours forever. Join in when something moves you.", .scale = meta_scale }},
                ),
                hgap(ui, 10),
                pillButton(ui, "Create identity", .open_join, true, p.surface_subbar),
                hgap(ui, 10),
                pillButton(ui, "Sign in", .open_join, false, p.surface_subbar),
                hgap(ui, 10),
                // An icon press, not a text button: the built-in x glyph (the
                // U+2715 codepoint is outside Geist's coverage, rendered tofu).
                // Padded well past the 12px glyph: the target is the press, not the
                // drawing.
                ui.row(.{
                    .padding = 6,
                    .on_press = .dismiss_guest_strip,
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Dismiss" },
                }, .{
                    ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.text_faint_alt } }, "x"),
                }),
                hgap(ui, chrome_inset),
            }),
            vgap(ui, 8),
            ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        }),
    });
}

/// The feed's scope line: which feed this is (the starter pack) and how wide it
/// reaches. A property of the feed, not a destination to choose between.
fn scopeHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // The scope name and the pack's size, on one line with the redesign's 11/16/9
    // insets. The label and the meta sit at opposite ends, so they are separate
    // runs rather than the single paragraph they shared when they were adjacent.
    //
    // No action lives here any more. Compose is the rail's bright tile, and a
    // guest reaches the join sheet from the banner or the rail's seat, so the
    // scope line is what it says it is: a label.
    // Centred WITHOUT grow: a row that is a child of a column grows on the
    // column's axis, so `.grow` here would stretch the header down the window and
    // shove the feed with it. A row already stretches across, which is all the
    // centring needs.
    return ui.row(.{ .main = .center }, .{ui.column(.{ .width = feed_column_width, .gap = 0 }, .{
        vgap(ui, 11),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, chrome_inset),
            // The name AND its chevron are the trigger, so the menu opens under
            // the word it names rather than off a 11px glyph.
            ui.stack(.{}, .{
                ui.row(.{
                    .cross = .center,
                    .gap = 7,
                    .on_press = Msg{ .toggle_menu = .scope },
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Choose feed", .focusable = true },
                }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_primary } },
                        &.{.{ .text = "Starter pack", .weight = .bold, .scale = scope_title_scale }},
                    ),
                    ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_muted } }, "chevron-down"),
                }),
                if (model.menu == .scope) scopeMenu(ui) else ui.spacer(0),
            }),
            ui.spacer(1),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_faint_alt } },
                &.{.{ .text = model.scope_voices(ui.arena), .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, chrome_inset),
        }),
        vgap(ui, 9),
        ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    })});
}

/// The status bar: the caught-up line on the left (there is no spinner, the feed
/// renders from disk), relay health on the right after an online dot.
fn statusBar(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        ui.separator(.{ .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
        // Four zones, every one pressable, and colour only where something needs
        // the reader. The chip row's own inset is 8, and the chips space at 4.
        ui.row(.{ .height = 30, .cross = .center, .gap = 0 }, .{
            hgap(ui, 8),
            // Feed state. Pressing it brings the newest note back to the top.
            statusChip(ui, .{
                .press = .jump_to_newest,
                .label = model.caught_up(ui.arena),
                .semantics = "Refresh the feed",
            }),
            ui.spacer(1),
            outboxZone(ui, model),
            relayZone(ui, model),
            hgap(ui, 4),
            signerZone(ui, model),
            hgap(ui, 8),
        }),
    });
}

/// The scope menu. One entry today, and it is the current one, so this exists to
/// say what the chevron means rather than to offer a choice: the reader learns
/// where scopes live before there is a second one to pick.
fn scopeMenu(ui: *AppUi) AppUi.Node {
    const rows = ui.arena.alloc(AppUi.Node, 1) catch return ui.spacer(0);
    rows[0] = menuRow(ui, "Starter pack", "check", null, .close_menu);
    // The scope line sits at the top of the window, so its menu drops down.
    return menuSurfacePlaced(ui, 200, .below, .start, rows);
}

/// The chrome's floating surface: a menu anchored to the trigger it hangs off.
///
/// Anchoring makes the surface leave its parent's flow entirely: it takes no
/// space in the row, paints in a late window-level pass above everything, and
/// escapes every ancestor clip, which is what lets a 30px status bar open a
/// 340px panel. It opens ABOVE, since the bar sits on the floor of the window,
/// and the runtime flips it if there is no room.
///
/// `on_dismiss` is what makes Escape and a press outside close it, so the model
/// never needs to hear about the click that landed elsewhere.
fn menuSurface(ui: *AppUi, width: f32, children: []const AppUi.Node) AppUi.Node {
    // A status-bar menu hangs off the right end of its chip, above the bar.
    return menuSurfacePlaced(ui, width, .above, .end, children);
}

/// The same surface with its placement stated, for a trigger that is not on the
/// floor of the window.
fn menuSurfacePlaced(ui: *AppUi, width: f32, placement: canvas.WidgetAnchorPlacement, alignment: canvas.WidgetAnchorAlignment, children: []const AppUi.Node) AppUi.Node {
    const p = theme.palette;
    return ui.el(.dropdown_menu, .{
        .width = width,
        .anchor = placement,
        .anchor_alignment = alignment,
        .anchor_offset = 6,
        .padding = 5,
        .on_dismiss = .close_menu,
        .style = .{ .background = p.surface_menu, .border = p.border_menu, .radius = 9, .stroke_width = 1 },
    }, .{
        ui.column(.{ .gap = 0 }, .{children}),
    });
}

/// One row in a chrome menu: a label, an optional glyph and an optional trailing
/// hint, at the redesign's 6 by 9 padding.
fn menuRow(ui: *AppUi, label: []const u8, glyph: ?[]const u8, hint: ?[]const u8, press: ?Msg) AppUi.Node {
    const p = theme.palette;
    // A plain row, deliberately: the `menu_item` kind is what the renderer would
    // wash on hover, but it lays its children out and then draws none of them
    // (the rows measured 330x32 and painted nothing at all). So a menu row has
    // no hover state until that is understood; the design specifies a SELECTED
    // row surface, which is a different state and is drawn.
    return ui.row(.{
        .cross = .center,
        .gap = 0,
        .on_press = press,
        .semantics = .{ .role = .button, .label = label, .focusable = press != null },
    }, .{
        hgap(ui, 9),
        vgap(ui, 25),
        if (glyph) |name| ui.appIcon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.text_secondary } }, name) else ui.spacer(0),
        if (glyph != null) hgap(ui, 9) else ui.spacer(0),
        ui.paragraph(.{ .style = .{ .foreground = p.text_body } }, &.{.{ .text = label, .scale = menu_scale }}),
        ui.spacer(1),
        if (hint) |text|
            ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = text, .monospace = true, .scale = mono_hint_scale }})
        else
            ui.spacer(0),
        hgap(ui, 9),
    });
}

/// A rule between groups of menu rows.
fn menuSeparator(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 4),
        ui.row(.{ .gap = 0 }, .{ hgap(ui, 7), ui.separator(.{ .grow = 1, .style = .{ .foreground = p.border_menu, .background = p.border_menu } }), hgap(ui, 7) }),
        vgap(ui, 4),
    });
}

/// The relay popover: every relay in the pool, what it is doing, and how fast it
/// answers, then the two things a reader can do about it.
fn relayPopover(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const rows = ui.arena.alloc(AppUi.Node, relays.len + 4) catch return ui.spacer(0);
    // The header says what the list means, so nobody reads it as a picker.
    rows[0] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 24),
        ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = "Relays", .weight = .medium, .scale = menu_scale }}),
        hgap(ui, 8),
        ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "reads & writes route automatically", .monospace = true, .scale = mono_meta_scale }}),
        ui.spacer(1),
        hgap(ui, 9),
    });
    for (relays, 0..) |url, i| {
        rows[1 + i] = relayRow(ui, url, i, model);
    }
    rows[relays.len + 1] = menuSeparator(ui);
    rows[relays.len + 2] = menuRow(ui, if (model.relays_paused) "Resume Relays" else "Pause Relays", null, null, .toggle_relays_paused);
    rows[relays.len + 3] = menuRow(ui, "Relay Settings…", null, "Cmd+,", .open_settings);
    return menuSurface(ui, 340, rows);
}

/// One relay in the popover: its state as a dot, its host, what it is for, and
/// how long it took to answer.
fn relayRow(ui: *AppUi, url: []const u8, index: usize, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const state: Conn = @enumFromInt(g_relay_status[index].load(.monotonic));
    // A relay leaves at its next message, so during a pause some rows are still
    // genuinely connected. Each row reports ITSELF: claiming the whole list is
    // paused while notes are still arriving on it is the dishonesty this is for.
    const connected = state == .connected;
    const paused = model.relays_paused and !connected;
    const dot = if (paused)
        p.text_faint_alt
    else if (connected)
        p.status_success
    else if (state == .connecting)
        p.status_warning
    else
        p.status_offline;
    // The host alone: the scheme is the same on every row and carries no news.
    const host = if (std.mem.startsWith(u8, url, "wss://")) url["wss://".len..] else url;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 21),
        ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = dot, .radius = 3, .stroke_width = 0 } }, .{}),
        hgap(ui, 8),
        ui.paragraph(.{ .style = .{ .foreground = if (connected) p.text_body else p.text_muted_alt } }, &.{.{ .text = host, .monospace = true, .scale = mono_row_scale }}),
        ui.spacer(1),
        if (connected) relayBadge(ui, "R·W") else ui.spacer(0),
        if (connected) hgap(ui, 8) else ui.spacer(0),
        // A connected relay reports its round trip; one that is still dialling or
        // has dropped says so in words instead of showing a stale number.
        ui.paragraph(
            .{ .style = .{ .foreground = if (connected) p.text_muted_alt else p.status_warning_text } },
            &.{.{
                .text = if (paused)
                    "paused"
                else if (connected)
                    (if (relayRttMs(index)) |ms| ui.fmt("{d}ms", .{ms}) else "…")
                else if (state == .connecting)
                    "connecting"
                else
                    "offline",
                .monospace = true,
                .scale = mono_meta_scale,
            }},
        ),
        hgap(ui, 9),
    });
}

/// The R·W chip on a relay row: what the relay is used for.
fn relayBadge(ui: *AppUi, text: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_menu, .border = p.border_dashed, .radius = 4, .stroke_width = 1 } }, .{
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 5),
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = text, .monospace = true, .scale = mono_badge_scale }}),
            hgap(ui, 5),
        }),
    });
}

/// The signed-in account's display name, or its npub until a kind:0 arrives.
fn accountName() []const u8 {
    if (activePubkey()) |pk| {
        if (lookupProfile(pk)) |profile| {
            if (profile.name_len > 0) return profile.name();
        }
    }
    return npubShort();
}

/// Whether a kind:0 name is known, so the npub is worth showing beneath it.
fn accountHasName() bool {
    if (activePubkey()) |pk| {
        if (lookupProfile(pk)) |profile| return profile.name_len > 0;
    }
    return false;
}

fn npubShort() []const u8 {
    return g_identity_npub_buf[0..g_identity_npub_len];
}

/// The account menu: who you are, and the two things to do about it. No mock
/// draws this, so it is the menu recipe with the identity row on top; flagged in
/// the PR for review.
fn accountMenu(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const rows = ui.arena.alloc(AppUi.Node, 4) catch return ui.spacer(0);
    rows[0] = ui.row(.{ .cross = .center, .gap = 0 }, .{
        hgap(ui, 9),
        vgap(ui, 34),
        youAvatar(ui),
        hgap(ui, 9),
        ui.column(.{ .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = accountName(), .weight = .medium, .scale = menu_scale }}),
            // The npub only when it is not already the name above it: an account
            // with no kind:0 yet would otherwise read its own key twice.
            if (accountHasName())
                ui.paragraph(.{ .style = .{ .foreground = p.text_label } }, &.{.{ .text = npubShort(), .monospace = true, .scale = mono_meta_scale }})
            else
                ui.spacer(0),
        }),
        ui.spacer(1),
        hgap(ui, 9),
    });
    rows[1] = menuSeparator(ui);
    rows[2] = menuRow(ui, "Settings…", "settings", "Cmd+,", .open_settings);
    rows[3] = menuRow(ui, "Sign out", null, null, .open_settings_logout);
    return menuSurface(ui, 240, rows);
}

/// The relay zone: the pool's health, and the popover that explains it. The chip
/// is highlighted while the pool is healthy, because that is when the number is
/// worth reading at a glance; a degraded pool speaks through its dot instead.
/// The banner 11p draws when no relay is answering. It says what still works,
/// which is nearly everything: the store is the app, so reading continues, and a
/// note written now is queued rather than refused. A spinner would say the
/// opposite.
fn offlineBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (liveRelayCount() > 0) return ui.spacer(0);
    const queued = model.outbox_pending;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = p.surface_offline, .border = p.border_offline, .radius = 8, .stroke_width = 1 },
            }, .{
                ui.row(.{ .cross = .center, .gap = 0 }, .{
                    hgap(ui, 11),
                    ui.column(.{ .gap = 0 }, .{
                        vgap(ui, 8),
                        ui.row(.{ .cross = .center, .gap = 0 }, .{
                            ui.icon(.{ .width = 13, .height = 13, .style = .{ .foreground = p.status_warning } }, "alert"),
                            hgap(ui, 8),
                            ui.paragraph(
                                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.status_warning_text } },
                                &.{.{ .text = offlineBannerText(ui, queued), .scale = meta_scale }},
                            ),
                        }),
                        vgap(ui, 8),
                    }),
                    hgap(ui, 11),
                }),
            }),
            hgap(ui, chrome_inset),
        }),
    });
}

/// What the banner says, which depends on whether anything is owed.
fn offlineBannerText(ui: *AppUi, queued: usize) []const u8 {
    if (queued == 0) return "No relay is answering. Reading continues from this machine; anything you write is kept until one does.";
    return ui.fmt("No relay is answering. Reading continues from this machine, and {d} {s} waiting to go out.", .{ queued, if (queued == 1) "note is" else "notes are" });
}

pub fn offlineBannerTextForTest(arena: std.mem.Allocator, queued: usize) []const u8 {
    var ui = AppUi.init(arena);
    return offlineBannerText(&ui, queued);
}

/// What the app still owes the reader. Absent when nothing is queued, which is
/// most of the time: a zone that is always there teaches nothing, and an empty
/// popover under it would be worse.
///
/// Amber, because this is work in progress rather than a warning: a note on its
/// way is the ordinary case. The glyph takes the text's own hex, not the
/// brighter alert amber.
fn outboxZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    if (model.outbox_pending == 0 and model.outbox_stuck == 0) return ui.spacer(0);
    const stuck = model.outbox_pending == 0 and model.outbox_stuck > 0;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = 22,
            .cross = .center,
            .on_press = Msg{ .toggle_menu = .outbox },
            .style = .{ .radius = 6, .background = if (model.menu == .outbox) p.surface_chip else null },
            .semantics = .{ .role = .button, .label = "Notes on their way", .focusable = true },
        }, .{
            hgap(ui, 7),
            // A runtime choice of glyph, so `appIcon` rather than the
            // comptime-checked `icon`.
            ui.appIcon(.{ .width = 11, .height = 11, .style = .{ .foreground = if (stuck) p.status_offline else p.status_warning_text } }, if (stuck) "alert" else "arrow-up"),
            hgap(ui, 6),
            ui.paragraph(
                .{ .style = .{ .foreground = if (stuck) p.status_offline else p.status_warning_text } },
                &.{.{ .text = model.outbox_label(ui.arena), .scale = status_scale }},
            ),
            hgap(ui, 7),
        }),
        if (model.menu == .outbox) outboxMenu(ui) else ui.spacer(0),
        hgap(ui, 4),
    });
}

/// One card per note on its way, newest first. No mock exists for this surface;
/// it is the smallest thing that answers the question the zone raises, which is
/// "which note, and how far did it get".
fn outboxMenu(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    var entries: [outbox_cap]OutboxEntry = undefined;
    const n = outboxSnapshot(&entries);
    if (n == 0) return ui.spacer(0);
    const rows = ui.arena.alloc(AppUi.Node, n) catch return ui.spacer(0);
    for (rows, entries[0..n]) |*row, e| {
        const title = switch (e.state()) {
            .queued => "Waiting for a relay",
            .sending => "Sending",
            .sent => "Sent",
            .stuck => "No relay took it",
        };
        row.* = ui.column(.{ .gap = 0 }, .{
            vgap(ui, 6),
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 9),
                ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{
                    .background = switch (e.state()) {
                        .queued => p.status_offline,
                        .sending => p.status_warning_text,
                        .sent => p.status_success,
                        .stuck => p.status_offline,
                    },
                    .radius = 3,
                    .stroke_width = 0,
                } }, .{}),
                hgap(ui, 8),
                ui.paragraph(.{ .style = .{ .foreground = p.text_secondary } }, &.{.{ .text = title, .weight = .medium, .scale = menu_scale }}),
                ui.spacer(1),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = ui.fmt("{d}/{d} relays", .{ e.ackCount(), relays.len }), .monospace = true, .scale = mono_hint_scale }},
                ),
                hgap(ui, 9),
            }),
            vgap(ui, 6),
        });
    }
    return menuSurface(ui, 240, rows);
}

fn relayZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const paused = model.relays_paused;
    const live = model.live_relays;
    // A paused pool that still has a socket open is PAUSING, not paused: a relay
    // leaves at its next message, and the bar refuses to claim otherwise.
    const settling = paused and live > 0;
    const dot = if (paused)
        p.text_faint_alt
    else if (live == 0)
        p.status_offline
    else if (!poolIsHealthy(live))
        p.status_warning
    else
        p.status_success;
    const label = if (settling)
        ui.fmt("pausing · {d}/{d} relays", .{ live, relays.len })
    else if (paused)
        ui.fmt("paused · 0/{d} relays", .{relays.len})
    else if (poolLatencyMs()) |ms|
        ui.fmt("{d}/{d} relays · {d} ms", .{ live, relays.len, ms })
    else
        ui.fmt("{d}/{d} relays", .{ live, relays.len });
    // The chip carries its plate when the pool is healthy AND when it is paused:
    // a deliberate pause is a state worth reading at a glance, not a fault.
    const plated = paused or poolIsHealthy(live);
    // The trigger and its floating surface are siblings in a stack: that is the
    // sanctioned shape, and the anchored surface takes no space in the row.
    return ui.stack(.{}, .{
        statusChip(ui, .{
            .press = Msg{ .toggle_menu = .relays },
            .label = label,
            .semantics = "Relays",
            .dot = dot,
            .chevron = true,
            .highlighted = plated,
            .ink = if (plated) p.text_secondary else p.text_muted,
        }),
        if (model.menu == .relays) relayPopover(ui, model) else ui.spacer(0),
    });
}

/// The signer zone: whether Plaza can sign right now, and the account menu.
fn signerZone(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    const guest = model.is_guest();
    // Name the signer that is actually in use, and say whether it can sign right
    // now. Claiming "Signet ready" for a local key or an unreachable bunker would
    // be a chip that lies about where the reader's key lives.
    const signer = signerStatus();
    return ui.stack(.{}, .{
        statusChip(ui, .{
            .press = if (guest) .open_join else Msg{ .toggle_menu = .account },
            .label = if (guest) "Guest" else signer.label,
            .semantics = if (guest) "Join" else "Account",
            .glyph = if (guest) "plus" else signer.glyph,
            .glyph_color = if (guest) p.text_faint_alt else signer.color,
        }),
        if (model.menu == .account) accountMenu(ui) else ui.spacer(0),
    });
}

/// Whether the pool counts as healthy: MOST of it answering, not all of it. The
/// redesign's at-rest bar reads "4/5 relays" in green while its working bar reads
/// "3/5" in amber, so the line sits at four fifths. A relay pool always has a
/// straggler, and a bar that goes amber for one is a bar nobody reads.
pub fn poolIsHealthyForTest(live: usize) bool {
    return poolIsHealthy(live);
}

fn poolIsHealthy(live: usize) bool {
    return live * 5 >= relays.len * 4;
}

/// What the status bar says about signing: which signer holds the key, and
/// whether it can be reached.
const SignerStatus = struct { label: []const u8, glyph: []const u8, color: canvas.Color };

fn signerStatus() SignerStatus {
    const p = theme.palette;
    return switch (g_signer_kind) {
        // Signet: a separate process, so its health is a real question.
        .helper => switch (g_helper_state.load(.monotonic)) {
            2 => .{ .label = "Signet ready", .glyph = "signet", .color = p.status_success },
            1 => .{ .label = "Signet has no key", .glyph = "signet", .color = p.status_warning },
            3 => .{ .label = "Signet unreachable", .glyph = "signet", .color = p.text_faint_alt },
            else => .{ .label = "Signet starting", .glyph = "signet", .color = p.status_warning },
        },
        // A remote bunker: reachable is the whole question, and the remote path
        // already tracks a failed round trip.
        .remote => if (g_remote_sign_notice.load(.acquire))
            .{ .label = "Signer unreachable", .glyph = "signet", .color = p.status_warning }
        else
            .{ .label = "Signer connected", .glyph = "signet", .color = p.status_success },
        // A key in this process: always able to sign, and honest about being local.
        .local => .{ .label = "Local key", .glyph = "signet", .color = p.status_success },
    };
}

/// One status-bar zone: a quiet pressable chip, highlighted only when it is
/// carrying live state the reader should look at.
const StatusChip = struct {
    press: Msg,
    label: []const u8,
    semantics: []const u8,
    /// A leading dot, for the relay zone's health.
    dot: ?canvas.Color = null,
    /// A leading glyph, for the signer zone and the offline warning.
    glyph: ?[]const u8 = null,
    glyph_color: canvas.Color = theme.palette.text_muted,
    /// A trailing chevron, for a chip that opens a menu.
    chevron: bool = false,
    highlighted: bool = false,
    ink: canvas.Color = theme.palette.text_muted,
};

fn statusChip(ui: *AppUi, chip: StatusChip) AppUi.Node {
    const p = theme.palette;
    // Gap 0 and explicit steps: a `gap` would space around the absent parts too,
    // so a chip with no dot and no chevron would carry their spacing anyway.
    const body = ui.row(.{ .cross = .center, .gap = 0 }, .{
        if (chip.dot) |color|
            ui.el(.panel, .{ .width = 6, .height = 6, .padding = 0.01, .style = .{ .background = color, .radius = 3, .stroke_width = 0 } }, .{})
        else
            ui.spacer(0),
        if (chip.dot != null) hgap(ui, 6) else ui.spacer(0),
        if (chip.glyph) |name|
            // `appIcon` takes a RUNTIME name and resolves built-ins first, then
            // the app table, so one call serves both vocabularies.
            ui.appIcon(.{ .width = 12, .height = 12, .style = .{ .foreground = chip.glyph_color } }, name)
        else
            ui.spacer(0),
        if (chip.glyph != null) hgap(ui, 6) else ui.spacer(0),
        ui.paragraph(.{ .style = .{ .foreground = chip.ink } }, &.{.{ .text = chip.label, .scale = status_scale }}),
        if (chip.chevron) hgap(ui, 6) else ui.spacer(0),
        if (chip.chevron)
            ui.icon(.{ .width = 10, .height = 10, .style = .{ .foreground = p.text_muted } }, "chevron-up")
        else
            ui.spacer(0),
    });
    // A highlighted chip carries a plate, so it needs a surface that paints; a
    // quiet one is text on the bar.
    const inner = if (chip.highlighted)
        ui.el(.panel, .{ .padding = 0.01, .style = .{ .background = p.surface_chip, .radius = 6, .stroke_width = 0 } }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{ hgap(ui, 8), vgap(ui, 22), body, hgap(ui, 8) }),
        })
    else
        ui.row(.{ .cross = .center, .gap = 0 }, .{ hgap(ui, 8), body, hgap(ui, 8) });
    return ui.row(.{
        .cross = .center,
        .on_press = chip.press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = chip.semantics, .focusable = true },
    }, .{inner});
}

/// One note: avatar, author line, content, and any inline image. Keyed by the
/// note id so the list diff holds scroll position across reconciles. This is
/// the per-row builder the windowed list will call in the milestone ahead.
/// The warm avatar tint for an author, chosen deterministically from the
/// pubkey so a face keeps the same color across sessions. Neutral graphite is
/// the last entry and the natural fallback for an all-zero key.
fn avatarTint(pubkey: [32]u8) theme.palette.Tint {
    const key = @as(usize, pubkey[0]) +% pubkey[15] +% pubkey[31];
    return theme.palette.avatar_tints[key % theme.palette.avatar_tints.len];
}

/// A chrome pill: the redesign's 26px-high button, filled for the primary verb
/// and outlined for the quiet one. The house button is a different shape (28 high
/// on its own scale), so the chrome states its own.
fn pillButton(ui: *AppUi, label: []const u8, press: Msg, filled: bool, on_surface: canvas.Color) AppUi.Node {
    const p = theme.palette;
    // The outlined variant paints the surface it sits on, not "nothing": a panel
    // with no stated background falls back to the house card fill, which would
    // draw a plate the redesign's ghost button does not have.
    const style: canvas.WidgetStyle = if (filled)
        .{ .background = p.accent, .radius = 7, .stroke_width = 0 }
    else
        .{ .background = on_surface, .border = p.border_control, .radius = 7, .stroke_width = 1 };
    const ink = if (filled) p.on_accent else p.text_secondary;
    // The shot sets the filled label at 600 and the ghost at 500; the bundled
    // family steps 400 / 500 / 700, so both land on medium.
    const weight: canvas.TextSpanWeight = .medium;
    // The fill and the outline live on a `.panel`: a row paints no background at
    // all (the renderer draws nothing for the layout kinds), which is why the
    // filled pill was reading as dark-on-dark text with no button under it.
    return ui.row(.{
        .on_press = press,
        .style = .{ .quiet_hover = true },
        .semantics = .{ .role = .button, .label = label, .focusable = true },
    }, .{
        ui.el(.panel, .{ .padding = 0.01, .style = style }, .{
            ui.row(.{ .height = 26, .cross = .center, .gap = 0 }, .{
                hgap(ui, 11),
                ui.paragraph(.{ .style = .{ .foreground = ink } }, &.{.{ .text = label, .weight = weight, .scale = meta_scale }}),
                hgap(ui, 11),
            }),
        }),
    });
}

/// A metadata run: the 12px register, in the ink the caller names.
fn metaText(ui: *AppUi, text: []const u8, color: canvas.Color) AppUi.Node {
    return ui.paragraph(.{ .style = .{ .foreground = color } }, &.{.{ .text = text, .scale = meta_scale }});
}

/// Fixed empty space along ONE axis. `ui.spacer(n)` takes a GROW factor, not a
/// size, so it cannot express an inset; these are the sized counterparts, used
/// wherever the redesign asks for a step that a uniform `padding` or `gap` cannot
/// state (a row inset of 12 top, 16 sides and 14 bottom; a column whose steps are
/// 5, 8 and 10). One axis each, so a spacer in a row never claims height and one
/// in a column never claims width.
fn hgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .width = size }, .{});
}

fn vgap(ui: *AppUi, size: f32) AppUi.Node {
    return ui.el(.stack, .{ .height = size }, .{});
}

/// The author disc: 36px, the tint keyed off the pubkey, initials when no
/// picture has been registered. The size is the redesign's, and it is what the
/// identity block beside it is pinned to.
fn noteAvatar(ui: *AppUi, note: *const Note) AppUi.Node {
    return avatarDisc(ui, note, avatar_size);
}

/// The same disc at an explicit size, for the surfaces that draw a smaller or
/// larger one (a nested thread child, a quote pill, a profile header).
fn avatarDisc(ui: *AppUi, note: *const Note, size: f32) AppUi.Node {
    const tint = avatarTint(note.pubkey);
    return ui.avatar(.{
        .image = note.avatar_id(),
        .width = size,
        .height = size,
        .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
    }, note.initials());
}

/// The identity block: the name over the handle, in a box pinned to the avatar's
/// height so the two lines sit against the disc's top and bottom edges. The
/// second line carries the verified check only when the author's NIP-05 actually
/// resolves to their pubkey; without a handle at all the block is just the name,
/// and the box still holds its height so a row never changes shape.
///
/// The redesign insets the two lines by 1px top and bottom. Padding is uniform
/// on this engine, and a 1px horizontal inset would push the name off the body's
/// left edge, so the box takes no padding: the name sits 1px higher and the
/// handle 1px lower than the mock, and every text run stays on one rail.
fn identityBlock(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    // `grow` so the block owns the width left over after the timestamp: the name
    // is a single line (no `wrap`), so a long display name ellipsizes inside the
    // block instead of pushing the time off the row. The mock leaves the block
    // hugging its text with a flexible spacer beside it, which has the same effect
    // for short names and loses the time for long ones.
    return ui.column(.{ .height = avatar_size, .grow = 1, .main = .space_between }, .{
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_primary } },
            &.{.{ .text = note.author(), .weight = .medium, .scale = name_scale }},
        ),
        handleLine(ui, note),
    });
}

/// The identity block's second line: the verified check, then the handle. The
/// check appears only when the author's NIP-05 resolved back to their pubkey, so
/// a claimed identity never wears a mark it has not earned.
fn handleLine(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    // Checked BEFORE the label: a profile in flight shows the bar, never a
    // placeholder handle that swaps a beat later.
    if (profileLoading(note.pubkey)) return ui.el(.skeleton, .{ .width = 72, .height = 9 }, .{});
    const label = note.handleLabel(ui.arena);
    if (label.text.len == 0) return ui.spacer(0);
    const handle = metaText(ui, label.text, if (label.nip05) p.accent_identity else p.text_faint);
    // The check and its 5px gap exist only when there IS a check. A row gap is
    // charged for every flow child, so substituting a zero-width spacer for the
    // glyph would still indent the handle 5px past the name's rail.
    if (!note.verified()) return handle;
    return ui.row(.{ .gap = 5, .cross = .center }, .{
        ui.icon(.{ .width = 12, .height = 12, .style = .{ .foreground = p.status_success } }, "check-circle"),
        handle,
    });
}

/// The engagement row: reply, repost, like, zap, in that fixed order, each an
/// icon and its crowd count (the count omitted at zero). Only the like is
/// pressable and only it carries an active state; reply, repost, and zap show
/// their tallies but stay non-actionable this pass.
fn engagementRow(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const glyph = AppUi.ElementOptions{ .width = 15, .height = 15, .style = .{ .foreground = theme.palette.text_metric } };
    const c = engagementFor(note.id);
    return ui.row(.{ .gap = 30, .cross = .center }, .{
        // Reply opens the note's thread, where the pinned composer answers it.
        // A plain pressable row, never a `.list_item`: that kind carries a 28px
        // intrinsic height floor and its padding walks the cluster off the rail
        // the disc, name and body share.
        ui.row(.{ .gap = 6, .cross = .center, .on_press = Msg{ .open_thread = note.id }, .style = .{ .quiet_hover = true }, .semantics = .{ .role = .button, .label = "Reply" } }, .{
            ui.appIcon(glyph, "reply"),
            countLabel(ui, c.replies, p.text_metric),
        }),
        ui.row(.{ .gap = 6, .cross = .center }, .{ ui.icon(glyph, "repeat"), countLabel(ui, c.reposts, p.text_metric) }),
        likeAction(ui, note),
        // The zap count is summed sats (msat / 1000); the action itself waits
        // on a wallet.
        ui.row(.{ .gap = 6, .cross = .center }, .{ ui.appIcon(glyph, "zap"), countLabel(ui, @intCast(c.zap_msat / 1000), p.text_metric) }),
    });
}

/// A count beside an action icon, or nothing at zero (so the icon stands alone
/// rather than showing a "0").
fn countLabel(ui: *AppUi, n: u64, color: canvas.Color) AppUi.Node {
    // `ui.spacer(0)` would still be charged the row's 6px gap, leaving a hole
    // where the count is not, so a zero count collapses the gap too.
    if (n == 0) return ui.el(.stack, .{ .width = 0, .height = 0 }, .{});
    return metaText(ui, formatCount(ui.arena, n), color);
}

/// The like control: a pressable heart and its count. Liked is never colour
/// alone (spec): the glyph fills red AND the count turns red together. The count
/// is the crowd's likes plus this session's own optimistic +1, which is dropped
/// once our own reaction comes back through the subscription (so it is not
/// counted twice).
fn likeAction(ui: *AppUi, note: *const Note) AppUi.Node {
    // Our own reaction id (if we liked this note), so the count can retire the
    // optimistic +1 once the reaction is folded into the crowd total.
    const my_reaction: ?[32]u8 = if (likeEntry(note.id)) |e| e.reaction_id else null;
    const liked = my_reaction != null;
    const count = likeCountFor(note.id, my_reaction);
    const tint = if (liked) theme.palette.status_like else theme.palette.text_metric;
    return ui.row(.{
        .gap = 6,
        .cross = .center,
        .style = .{ .quiet_hover = true },
        .on_press = Msg{ .like = note.id },
        .semantics = .{ .role = .button, .label = if (liked) "Unlike" else "Like", .focusable = true },
    }, .{
        ui.appIcon(.{ .width = 15, .height = 15, .style = .{ .foreground = tint } }, "like"),
        countLabel(ui, count, tint),
    });
}

/// Formats an engagement count: the integer below 1000, one-decimal `k` above,
/// and empty at zero so the caller draws the icon alone rather than a "0".
pub fn formatCount(arena: std.mem.Allocator, n: u64) []const u8 {
    if (n == 0) return "";
    if (n < 1000) return std.fmt.allocPrint(arena, "{d}", .{n}) catch "";
    const k = @as(f64, @floatFromInt(n)) / 1000.0;
    return std.fmt.allocPrint(arena, "{d:.1}k", .{k}) catch "";
}

// Which long notes the reader has expanded past the "Show more" fold, by note
// id. Session-only and small: few notes are open at once, so a linear set with
// LRU-ish eviction is plenty. Id 0 marks an empty slot (a note's id is masked
// non-negative and never 0 in practice, the same sentinel `viewing_thread` uses).
const expanded_cap = 64;
/// The pictures the reader has asked for while previews are off. A per-note UI
/// fact, so it lives beside the reader rather than on the Note, which is rebuilt
/// from the store on every refresh. Oldest asked is dropped when it fills, the
/// same shape as the expanded-notes ring.
const asked_cap = 32;
var g_media_asked = [_]i64{0} ** asked_cap;

pub fn isMediaAsked(note_id: i64) bool {
    for (g_media_asked) |a| {
        if (a == note_id) return true;
    }
    return false;
}

fn askForMedia(note_id: i64) void {
    if (isMediaAsked(note_id)) return;
    for (&g_media_asked) |*a| {
        if (a.* == 0) {
            a.* = note_id;
            return;
        }
    }
    std.mem.copyForwards(i64, g_media_asked[0 .. asked_cap - 1], g_media_asked[1..]);
    g_media_asked[asked_cap - 1] = note_id;
}

pub fn askForMediaForTest(note_id: i64) void {
    askForMedia(note_id);
}

pub fn forgetAskedMediaForTest() void {
    g_media_asked = [_]i64{0} ** asked_cap;
}

var g_expanded = [_]i64{0} ** expanded_cap;

fn isExpanded(note_id: i64) bool {
    for (g_expanded) |e| {
        if (e == note_id) return true;
    }
    return false;
}

/// Toggles whether `note_id`'s long body is expanded. Evicts the oldest slot
/// when the (generous) set is full rather than refusing to expand.
fn toggleExpanded(note_id: i64) void {
    for (&g_expanded) |*e| {
        if (e.* == note_id) {
            e.* = 0;
            return;
        }
    }
    for (&g_expanded) |*e| {
        if (e.* == 0) {
            e.* = note_id;
            return;
        }
    }
    g_expanded[0] = note_id;
}

/// The byte length of `text` to show collapsed: the whole thing when it is not
/// long, else a prefix near `max` that ends on a codepoint boundary and, when
/// one is close, a word boundary, so the fold never cuts mid-word or mid-glyph.
fn collapsedLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var end = max;
    // Back to the start of a codepoint (never mid-sequence).
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    // Prefer the last space/newline in the final quarter, so a word stays whole.
    const floor = (max * 3) / 4;
    var w = end;
    while (w > floor and text[w - 1] != ' ' and text[w - 1] != '\n') w -= 1;
    if (w > floor) end = w;
    return end;
}

/// Whether a note is long enough to collapse: comfortably past the fold, so a
/// note only a line or two over is shown whole rather than hiding a few words.
fn noteIsLong(note: *const Note) bool {
    return note.content_len > note_collapse_chars + 80;
}

/// A styled body paragraph, the same shape everywhere text is rendered.
fn textPara(ui: *AppUi, spans: []const canvas.TextSpan) AppUi.Node {
    return textParaAt(ui, spans, 1, theme.palette.text_body);
}

/// The same paragraph at a stated register and ink: the thread's focal note reads
/// one step up from a feed row, and a shade brighter.
fn textParaAt(ui: *AppUi, spans: []const canvas.TextSpan, scale: f32, ink: canvas.Color) AppUi.Node {
    const sized = if (scale == 1) spans else blk: {
        const out = ui.arena.alloc(canvas.TextSpan, spans.len) catch break :blk spans;
        for (spans, out) |src, *dst| {
            dst.* = src;
            // A span that already states its own scale keeps its ratio to the
            // body around it.
            dst.scale = (if (src.scale == 0) 1 else src.scale) * scale;
        }
        break :blk out;
    };
    return ui.paragraph(.{ .wrap = true, .on_link = AppUi.linkMsg(.open_url), .style = .{ .foreground = ink } }, sized);
}

/// A note's body: the styled text, an embedded quote card where the note quotes
/// another event, and a "Show more" affordance when it is long (unless the reader
/// has expanded it, or `collapsible` is false, as for a thread's focused root).
/// The body splits around the quoted event's raw token (its byte span), never
/// cutting the card; a quote at or past the fold appears only once expanded.
fn noteBody(ui: *AppUi, note: *const Note, collapsible: bool) AppUi.Node {
    return noteBodyAt(ui, note, collapsible, 1, theme.palette.text_body);
}

/// The body at a stated register: everything above, one step larger, for the note
/// a thread is about.
fn noteBodyAt(ui: *AppUi, note: *const Note, collapsible: bool, scale: f32, ink: canvas.Color) AppUi.Node {
    const p = theme.palette;
    const full = note.content();
    const long = collapsible and noteIsLong(note);
    const expanded = long and isExpanded(note.id);
    const cut: usize = if (long and !expanded) collapsedLen(full, note_collapse_chars) else full.len;
    const q = note.quote;
    const card_end = @as(usize, q.off) + @as(usize, q.len);
    const has_card = q.kind == .event and card_end <= cut;

    // Fast path unchanged: a plain note with no fold is exactly one paragraph.
    if (!has_card and !long) return textParaAt(ui, contentSpans(ui, full[0..cut]), scale, ink);

    var kids: [5]AppUi.Node = undefined;
    var n: usize = 0;
    if (has_card) {
        const head = std.mem.trim(u8, full[0..q.off], " \t\r\n");
        if (head.len > 0) {
            kids[n] = textParaAt(ui, contentSpans(ui, head), scale, ink);
            n += 1;
        }
        kids[n] = quoteRule(ui, q.id);
        n += 1;
        const tail = std.mem.trim(u8, full[card_end..cut], " \t\r\n");
        if (tail.len > 0) {
            kids[n] = textParaAt(ui, contentSpans(ui, tail), scale, ink);
            n += 1;
        }
    } else {
        kids[n] = textParaAt(ui, contentSpans(ui, full[0..cut]), scale, ink);
        n += 1;
    }
    if (long) {
        // A deeper hit target than the row's open-thread press, so tapping it
        // toggles the fold rather than opening the thread.
        kids[n] = ui.el(.data_row, .{ .on_press = Msg{ .toggle_expand = note.id }, .padding = 2, .style = .{ .quiet_hover = true }, .semantics = .{ .role = .button, .label = if (expanded) "Show less" else "Show more" } }, .{
            ui.text(.{ .size = .sm, .style = .{ .foreground = p.text_secondary } }, if (expanded) "Show less" else "Show more"),
        });
        n += 1;
    }
    return ui.column(.{ .gap = 8 }, .{kids[0..n]});
}

/// An embedded quote card for a quoted event `id`: a bordered inset showing the
/// quoted author and a truncated body, tappable to open it. Loading and
/// unavailable states are non-pressable and hold the same height, so the feed
/// never reflows as the quote resolves. The author is drawn as initials-on-tint
/// (`image = 0`), so a quote card never competes for the scarce avatar ids.
fn quoteRule(ui: *AppUi, id: [32]u8) AppUi.Node {
    const p = theme.palette;
    const e = quoteFor(id);
    if (e == null or e.?.state == .idle or e.?.state == .fetching) {
        // A reused feed note (never re-parsed) whose quote slot was reclaimed by
        // a newer quote lands here with no cache entry; re-queue it so the next
        // tick resolves it again instead of showing a skeleton forever.
        if (e == null) wantQuote(id);
        return quoteAside(ui, null, ui.el(.skeleton, .{ .height = 34 }, .{}));
    }
    const q = e.?;
    if (q.state == .missing) {
        return quoteAside(ui, null, ui.paragraph(
            .{ .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = "Quoted note unavailable", .scale = nested_body_scale }},
        ));
    }

    // A synthetic note, so the quote wears the SAME identity recipe as every
    // other row instead of a second one built from the cache's parts. Writing a
    // parallel builder is what cost the focal note its quote card once already.
    const note = ui.arena.create(Note) catch return ui.spacer(0);
    note.* = .{ .pubkey = q.pubkey, .created_at = q.created_at };
    const hexdigits = "0123456789abcdef";
    note.initials_buf = .{ hexdigits[q.pubkey[0] >> 4], hexdigits[q.pubkey[0] & 0x0f] };
    setAuthor(note, q.pubkey);
    note.setTime(nowSeconds());
    const text = q.text_buf[0..q.text_len];
    @memcpy(note.content_buf[0..text.len], text);
    note.content_len = @intCast(text.len);
    // The quoted note's OWN reference is drawn as the pill below, so it comes
    // out of the body: left in, it is a hundred characters of bech32 that no
    // line break can split, which runs straight out of the reading column.
    findQuoteRef(note);
    if (note.quote.kind == .event) {
        const cut_start = @as(usize, note.quote.off);
        const cut_end = cut_start + @as(usize, note.quote.len);
        if (cut_end <= note.content_len) {
            const tail = note.content_buf[cut_end..note.content_len];
            std.mem.copyForwards(u8, note.content_buf[cut_start..], tail);
            note.content_len = @intCast(cut_start + tail.len);
            const trimmed = std.mem.trimEnd(u8, note.content_buf[0..note.content_len], " \n\r\t");
            note.content_len = @intCast(trimmed.len);
        }
    }

    // `grow` so the quote fills the column beside the rule: hugging its content,
    // the body wrapped at about half the width the shot gives it.
    return quoteAside(ui, id, ui.column(.{ .grow = 1, .gap = 4 }, .{
        ui.row(.{ .gap = 10, .cross = .start }, .{
            avatarDisc(ui, note, avatar_size),
            identityBlock(ui, note),
            ui.paragraph(.{ .style = .{ .foreground = p.text_faint_alt } }, &.{.{ .text = note.time(), .scale = meta_scale }}),
        }),
        // Four lines of the quoted note, and no more: a quote is an aside, and
        // its height has to be known where the outer row is priced.
        quoteBody(ui, note),
        // A quote of a quote stops here. One more body would be a third voice in
        // a row, so the second hop is a pill that says where it goes.
        if (q.has_quote_of) quotingPill(ui, q.quote_of) else ui.spacer(0),
    }));
}

/// The quoted note's own words, four lines of them. Labelled, because the one
/// thing worth asserting about it is how WIDE it is: hugging its content instead
/// of filling the column beside the rule, it wrapped at about half the width the
/// shot gives it and read as a column of its own rather than an aside.
fn quoteBody(ui: *AppUi, note: *const Note) AppUi.Node {
    const spans = clampSpansToLines(ui, contentSpans(ui, note.content()), quote_body_lines);
    var node = textParaAt(ui, spans, nested_body_scale, theme.palette.text_secondary_alt);
    node.widget.semantics.label = "Quoted note body";
    return node;
}

/// 11g's pill: where the quoted note's own quote goes, one hop, as a line rather
/// than a third nested body. Pressing it walks that hop.
fn quotingPill(ui: *AppUi, id: [32]u8) AppUi.Node {
    const p = theme.palette;
    const tint = avatarTint(quotingPillAuthor(id));
    const hexdigits = "0123456789abcdef";
    const author = quotingPillAuthor(id);
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = quote_pill_height,
            .cross = .center,
            .on_press = Msg{ .open_event = id },
            .style = .{ .background = p.surface_pill, .border = p.border_pill, .radius = 999, .stroke_width = 1 },
            .semantics = .{ .role = .button, .label = "Quoted note inside it", .focusable = true },
        }, .{
            hgap(ui, 4),
            ui.avatar(.{
                .image = 0,
                .width = 14,
                .height = 14,
                .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
            }, ui.fmt("{c}{c}", .{ hexdigits[author[0] >> 4], hexdigits[author[0] & 0x0f] })),
            hgap(ui, 6),
            // ONE line, elided at the tail: the pill says where the hop goes and
            // begins what it says, and a long note may not push the row wider.
            // `wrap = false` is what makes the single-line overflow policy apply.
            ui.text(.{
                .width = quote_pill_label_width,
                .wrap = false,
                .overflow = .ellipsis,
                .size = .sm,
                .style = .{ .foreground = p.text_muted_alt },
            }, quotingPillLabel(ui, id)),
            hgap(ui, 9),
        }),
        // Hugging its content, so the pill is a pill and not a bar.
        ui.spacer(1),
    });
}

/// `text` with its line breaks folded into spaces, for a control that is one
/// line by construction. A widget that measures single-line still PAINTS the
/// newlines its text carries, so an unfolded label draws its second line over
/// whatever is under the row.
fn oneLine(ui: *AppUi, text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n") == null) return text;
    const out = ui.arena.alloc(u8, text.len) catch return text;
    var n: usize = 0;
    var last_space = false;
    for (text) |c| {
        const space = c == '\n' or c == '\r' or c == ' ' or c == '\t';
        if (space) {
            if (last_space or n == 0) continue;
            out[n] = ' ';
        } else {
            out[n] = c;
        }
        last_space = space;
        n += 1;
    }
    return out[0..n];
}

pub fn oneLineForTest(ui: *AppUi, text: []const u8) []const u8 {
    return oneLine(ui, text);
}

/// Whose note the pill walks to, once that note is resolved; a zero key until
/// then, which tints the disc neutrally rather than guessing.
fn quotingPillAuthor(id: [32]u8) [32]u8 {
    const e = quoteFor(id) orelse return [_]u8{0} ** 32;
    if (e.state != .loaded) return [_]u8{0} ** 32;
    return e.pubkey;
}

/// What the pill says. It names the author once that note has arrived, and says
/// plainly that it is still coming until then, rather than showing a name it
/// does not have.
fn quotingPillLabel(ui: *AppUi, id: [32]u8) []const u8 {
    // Re-queued when the entry is gone, the same way the aside itself does it:
    // the pill's target is asked for once, when the note holding it is filled,
    // and the 64-entry cache can evict it while the pill is still on screen. Then
    // nothing would ever ask again, because the note holding it is loaded and a
    // loaded entry is never revisited.
    const e = quoteFor(id) orelse {
        wantQuote(id);
        return "Quoting a note";
    };
    return switch (e.state) {
        // Whose note, and the start of what it says: the shot's own pill reads
        // "Quoting @edith · Shipping it: the feed renders…", so the reader can
        // tell whether the hop is worth taking before taking it.
        .loaded => ui.fmt("Quoting {s} · {s}", .{ quotePillHandle(ui, e.pubkey), oneLine(ui, e.text_buf[0..e.text_len]) }),
        .missing => "Quotes a note no relay has",
        else => "Quoting a note",
    };
}

/// The handle for a pill: `@name` when the author has one, else their display
/// name, else a short npub. The pill is one line, so it names them the shortest
/// true way rather than the fullest.
fn quotePillHandle(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |pr| {
        if (pr.nip05_len > 0) {
            const nip05 = pr.nip05();
            if (std.mem.indexOfScalar(u8, nip05, '@')) |at| {
                const local = nip05[0..at];
                const shown = if (std.mem.eql(u8, local, "_")) nip05[at + 1 ..] else local;
                if (shown.len > 0) return std.fmt.allocPrint(ui.arena, "@{s}", .{shown}) catch "";
            }
        }
        const user = pr.username();
        if (user.len > 0) return std.fmt.allocPrint(ui.arena, "@{s}", .{user}) catch "";
    }
    return quoteAuthorName(ui, pubkey);
}

/// The rule down the left of a quote, and whatever sits beside it. The redesign
/// replaces the bordered card with this: a card inside a row reads as a second
/// surface competing with the note, where the rule reads as an aside, which is
/// what a quote is.
///
/// `id` non-null makes the block open that note. The rule brightening on hover
/// (11f) is not expressible: hover is a background wash on one widget, and a
/// wash here would be a state the design does not draw.
fn quoteAside(ui: *AppUi, id: ?[32]u8, body: AppUi.Node) AppUi.Node {
    const p = theme.palette;
    // `grow` on the row, so the aside is as wide as the column it sits in. Its
    // parent is a column, where grow is the vertical axis for the WRAPPER but the
    // width for this row's own sizing: without it the row took its intrinsic
    // width, which for a long quote measured three times the window.
    const inner = ui.row(.{ .grow = 1, .gap = 0 }, .{
        // The rule takes the row's height from the default cross STRETCH. It must
        // not `grow`: grow in a row is the horizontal axis, so a growing 2px rule
        // and the growing content column split the width between them, and the
        // quote wrapped at half the space the shot gives it. The thread's rail
        // uses the same construct correctly because it sits in a COLUMN, where
        // grow is the axis it wants.
        ui.separator(.{ .width = 2, .style = .{ .foreground = p.divider_reply, .background = p.divider_reply } }),
        hgap(ui, 12),
        ui.column(.{ .grow = 1, .gap = 0 }, .{
            vgap(ui, 2),
            body,
            vgap(ui, 2),
        }),
    });
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 5),
        if (id) |event_id|
            // A plain row: it paints nothing, which is right, because 11f gives a
            // quote no hover state (its rule brightening is not expressible) and
            // a wash here would invent one. It also MEASURES, which `list_item`
            // does not: the width-aware measurer has no case for that kind, so a
            // wrapping quote body would measure one line tall and draw over the
            // verbs under it.
            ui.row(.{
                .grow = 1,
                // By EVENT id, read straight from the store: a quoted note is in
                // neither the feed nor the open thread's replies.
                .on_press = Msg{ .open_event = event_id },
                .semantics = .{ .role = .button, .label = "Quoted note" },
            }, .{inner})
        else
            inner,
    });
}

/// Seeds a resolved quote, so a test can render the aside and price it without a
/// relay. Returns the id it was filed under.
pub fn seedQuoteForTest(id: [32]u8, pubkey: [32]u8, created_at: i64, text: []const u8) void {
    wantQuote(id);
    const e = quoteFor(id) orelse return;
    e.pubkey = pubkey;
    e.created_at = created_at;
    const keep = @min(text.len, e.text_buf.len);
    @memcpy(e.text_buf[0..keep], text[0..keep]);
    e.text_len = @intCast(keep);
    e.state = .loaded;
}

pub fn quoteForTest(id: [32]u8) ?*QuoteEntry {
    return quoteFor(id);
}

pub fn dropQuoteForTest(id: [32]u8) void {
    for (&g_quotes) |*q| {
        if (q.used and std.mem.eql(u8, &q.id, &id)) q.* = .{};
    }
}

pub fn quotingPillLabelForTest(ui: *AppUi, id: [32]u8) []const u8 {
    return quotingPillLabel(ui, id);
}

pub fn quoteBodyLinesForTest(e: *const QuoteEntry) f32 {
    return quoteBodyLines(e);
}

pub fn noteRowEstimateForTest(note: *const Note, chrome: f32) f32 {
    return noteRowEstimate(note, chrome);
}

/// The quoted author's display name (from the profile cache) or a short npub.
fn quoteAuthorName(ui: *AppUi, pubkey: [32]u8) []const u8 {
    if (lookupProfile(pubkey)) |pr| {
        if (pr.name_len > 0) return pr.name();
    }
    const buf = ui.arena.alloc(u8, 24) catch return "";
    return abbreviateNpub(buf, pubkey);
}

/// The focal note's timestamp in full: the time and the date, since a note being
/// read deserves to say exactly when it was written rather than "3h".
fn absoluteNoteTime(arena: std.mem.Allocator, created_at: i64) []const u8 {
    // LOCAL time, because a reader reads a clock, not an offset. Neither the SDK
    // nor the standard library carries a timezone database, so the offset comes
    // from libc, which knows the zone and the daylight rule. Off macOS (the
    // portability build) there is no such call wired, and the line says UTC
    // rather than pretending.
    const shifted = created_at + localOffsetSeconds(created_at);
    const secs: u64 = @intCast(@max(shifted, 0));
    const days = secs / 86_400;
    const day_secs = secs % 86_400;
    const hour24 = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const pm = hour24 >= 12;
    const hour12 = if (hour24 % 12 == 0) 12 else hour24 % 12;
    // Civil date from the Unix epoch, by Howard Hinnant's algorithm: exact, and
    // no dependency on a timezone database the app does not carry.
    const z = @as(i64, @intCast(days)) + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36_524) - @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_name = months[@intCast(@min(@max(m - 1, 0), 11))];
    return std.fmt.allocPrint(arena, "{d}:{d:0>2} {s}{s} · {s} {d}, {d}", .{
        hour12, minute, if (pm) "PM" else "AM", if (comptime builtin.os.tag == .macos) "" else " UTC", month_name, d, year,
    }) catch "";
}

/// Seconds to add to a Unix timestamp to get local wall-clock time, from libc's
/// own zone handling (so daylight saving is right, and right for the DATE in
/// question rather than for today).
fn localOffsetSeconds(unix_seconds: i64) i64 {
    if (comptime builtin.os.tag != .macos) return 0;
    var tm: c_tm = std.mem.zeroes(c_tm);
    const t: i64 = unix_seconds;
    if (localtime_r(&t, &tm) == null) return 0;
    return tm.tm_gmtoff;
}

/// The fields of `struct tm` this needs, in libc's order. Only `tm_gmtoff` is
/// read; the rest are here so the struct is the right size for libc to fill.
const c_tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern "c" fn localtime_r(timer: *const i64, result: *c_tm) ?*c_tm;

/// Who a reply is addressed to: the handle when one is known, else the display
/// name, which is all a profile without a nip05 offers.
fn replyTarget(ui: *AppUi, note: *const Note) []const u8 {
    const handle = note.handle(ui.arena);
    return if (handle.len > 0) handle else note.author();
}

/// One phrase or the other, by count. English, and the only two shapes the
/// chrome needs.
fn pluralize(ui: *AppUi, n: usize, comptime one: []const u8, comptime many: []const u8) []const u8 {
    return if (n == 1) ui.fmt(one, .{n}) else ui.fmt(many, .{n});
}

/// How many relays are connected right now.
fn liveRelayCount() usize {
    var n: usize = 0;
    for (0..relays.len) |i| {
        const state: Conn = @enumFromInt(g_relay_status[i].load(.monotonic));
        if (state == .connected) n += 1;
    }
    return n;
}

/// A note's nevent, abbreviated for a chip: enough to recognise, short enough to
/// sit beside a timestamp.
fn shortNevent(ui: *AppUi, note: *const Note) []const u8 {
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const addr = nostr.nip19.encodeNevent(fba.allocator(), note.event_id, &.{}, note.pubkey, 1) catch return "nevent";
    if (addr.len <= 18) return ui.fmt("{s}", .{addr});
    return ui.fmt("{s}…{s}", .{ addr[0..10], addr[addr.len - 4 ..] });
}

/// The quoted note's relative timestamp, computed for the frame.
fn quoteTime(ui: *AppUi, created_at: i64) []const u8 {
    const dt = nowSeconds() - created_at;
    if (dt < 60) return "now";
    if (dt < 3600) return ui.fmt("{d}m", .{@divTrunc(dt, 60)});
    if (dt < 86_400) return ui.fmt("{d}h", .{@divTrunc(dt, 3600)});
    if (dt < 604_800) return ui.fmt("{d}d", .{@divTrunc(dt, 86_400)});
    return ui.fmt("{d}w", .{@divTrunc(dt, 604_800)});
}

/// One feed note: a bare row on the window, no card. Avatar column, then an
/// identity line (name, and the time hung to the right), the body, any image,
/// and the engagement row. The content is a fixed reading column centered in
/// the window, with a hairline under each row as the only separation. Keyed by
/// the note id so the list diff holds scroll position across reconciles.
fn noteCard(ui: *AppUi, note: *const Note) AppUi.Node {
    var node = ui.row(.{ .grow = 1, .main = .center }, .{
        ui.column(.{ .width = feed_column_width }, .{
            // A `list_item`, because that is the kind the renderer washes on
            // hover, and the row wash is the redesign's one hover state. It has
            // to be given an explicit WIDTH: a list_item sizes to its content,
            // and without one the body paragraph ran to its unwrapped width and
            // overflowed the reading column. Its children lay out on the
            // horizontal axis, so the single column below is what holds the
            // vertical stack. The inner controls (like, reply, links, the
            // picture) keep their own presses as the deeper hit targets.
            //
            // Every inset is stated once, on the axis that owns it: this column
            // carries the redesign's 12 above and 14 below, the row inside it
            // carries 16 on each side and the 12 between disc and text, and the
            // content column's own steps are 5, 8 and 10. A uniform `padding`
            // cannot express any of that, and a `gap` on the row would also apply
            // around each inset box, which is what threw the first attempt 12px
            // off the reading rail.
            ui.el(.data_row, .{ .width = feed_column_width, .padding = 0.01, .on_press = Msg{ .open_thread = note.id }, .semantics = .{ .label = "Open thread" } }, .{ui.column(.{ .gap = 0, .width = feed_column_width }, .{
                vgap(ui, row_pad_top),
                ui.row(.{ .gap = 0, .cross = .start }, .{
                    hgap(ui, row_pad_side),
                    noteAvatar(ui, note),
                    hgap(ui, avatar_to_text_gap),
                    ui.column(.{ .gap = 0, .grow = 1 }, .{
                        // The identity header: the name over the handle in a box
                        // the avatar's height, with the time hung top-right.
                        ui.row(.{ .gap = 6, .cross = .start }, .{
                            identityBlock(ui, note),
                            metaText(ui, note.time(), theme.palette.text_faint_alt),
                        }),
                        vgap(ui, 5),
                        noteBody(ui, note, true),
                        // The picture. The space is reserved at the picture's own
                        // shape whether or not it has loaded, so the feed never
                        // shifts as images arrive.
                        if (note.hasImage()) vgap(ui, 8) else ui.spacer(0),
                        if (note.hasImage()) notePicture(ui, note) else ui.spacer(0),
                        if (note.hasLink()) linkCard(ui, note) else ui.spacer(0),
                        vgap(ui, 10),
                        engagementRow(ui, note),
                    }),
                    hgap(ui, row_pad_side),
                }),
                vgap(ui, row_pad_bottom),
            })}),
            // The only separation between rows: a hairline. The `.separator`
            // element paints a real line (an empty column with a background does
            // not, which is why every divider was invisible before).
            ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = theme.palette.divider_row, .background = theme.palette.divider_row } }),
        }),
    });
    // The note id is masked non-negative at build time, so this cast is safe.
    node.key = .{ .int = @intCast(note.id) };
    return node;
}

/// Splits rendered note text into styled runs so a note reads like a note.
/// Every interactive run takes the identity violet, because each one names a
/// person or something they wrote: an `@mention` (one weight up, the way a name
/// is set), a `#hashtag`, a bare `nostr:` event reference, and a web link, which
/// alone carries a pressable payload. The design shows no hashtag, so their
/// color follows the redesign's stated rule ("violet for identity and content")
/// rather than a shot.
/// Every span's text is a subslice of the note's own content, so nothing is
/// copied. A paragraph holds at most 32 runs, so a link-heavy note keeps its
/// tail as one plain run rather than losing it.
pub fn contentSpans(ui: *AppUi, text: []const u8) []const canvas.TextSpan {
    const max_spans = 32;
    if (text.len == 0) return &.{};
    const spans = ui.arena.alloc(canvas.TextSpan, max_spans) catch return &.{};

    var n: usize = 0;
    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < text.len) {
        const is_url = std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://");
        const is_mention = text[i] == '@' and i + 1 < text.len and !std.ascii.isWhitespace(text[i + 1]);
        // A hashtag is `#` + word characters at a word boundary, so `C#` and a
        // URL fragment (`…#section`) are left as plain text.
        const is_hashtag = text[i] == '#' and i + 1 < text.len and isHashtagChar(text[i + 1]) and (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]));
        // A `nostr:nevent`/`note`/`naddr` reference (the first is usually lifted
        // into a quote card upstream; a second one, or one inside a quoted body,
        // still reads as a reference here). No link: there is no in-app target
        // for a bare extra ref yet.
        const is_eventref = isEventRefStart(text, i);
        if (!is_url and !is_mention and !is_hashtag and !is_eventref) {
            i += 1;
            continue;
        }
        // Two slots for this run plus the trailing plain run.
        if (n + 3 > max_spans) break;
        if (i > plain_start) {
            spans[n] = .{ .text = text[plain_start..i] };
            n += 1;
        }
        var j = i;
        if (is_hashtag) {
            // Just the tag word: trailing punctuation (`#nostr!`) stays plain.
            j = i + 1;
            while (j < text.len and isHashtagChar(text[j])) j += 1;
        } else {
            while (j < text.len and !std.ascii.isWhitespace(text[j])) j += 1;
        }
        const run = text[i..j];
        // Content color is the identity violet, reached through the `info`
        // token (a span names a token field, not a Color). A @mention
        // additionally sits one weight up, the way a name does.
        //
        // The redesign draws an in-text URL colored and NOTHING more, but the
        // renderer underlines every span that carries a link payload
        // (`span.underline or is_link`), so a clickable URL is always underlined.
        // Clickability wins over the hairline: `underline` stays unset here to
        // say what we asked for, and the extra rule is the renderer's.
        spans[n] = if (is_url)
            .{ .text = run, .color = .info, .link = run }
        else if (is_mention)
            .{ .text = run, .color = .info, .weight = .medium }
        else
            .{ .text = run, .color = .info };
        n += 1;
        i = j;
        plain_start = j;
    }
    if (plain_start < text.len and n < max_spans) {
        spans[n] = .{ .text = text[plain_start..] };
        n += 1;
    }
    return spans[0..n];
}

/// The height a note's picture occupies, whether or not it has loaded. Taken
/// from the note's declared `imeta` shape, else the shape it turned out to be
/// last time it was decoded, else a gentle default. Clamped so one very tall
/// image cannot take over the feed.
pub fn pictureHeight(note: *const Note) f32 {
    // The picture spans the reading column, which is what 11o draws, and takes
    // exactly the height the note's own `imeta` implies at that width. It was
    // based on a 300px box and clamped at 320px, so a tall picture was reserved
    // at a height it never drew and the row shifted when the bytes arrived, which
    // is the whole thing a declared shape exists to prevent.
    //
    // The cap is on the ASPECT, not the pixels: a very tall picture is contained
    // rather than allowed to take over the feed, and contained at a height the
    // estimate can state exactly.
    return picture_column_width * @min(pictureAspect(note), picture_max_aspect);
}

/// The shape to draw at: what the note declares, else what this picture measured
/// when it was last decoded (remembered past its slot, so an evicted picture does
/// not shrink and shift the feed), else a landscape guess.
fn pictureAspect(note: *const Note) f32 {
    if (note.image_aspect > 0) return note.image_aspect;
    return recalledAspect(note.id) orelse picture_default_aspect;
}

/// A note's picture: the image once registered, or a placeholder holding the
/// exact same space while it loads. Drawn with `contain` at its own aspect, so
/// it is never stretched and stays undistorted as the window resizes. Pressing
/// it opens the viewer.
fn notePicture(ui: *AppUi, note: *const Note) AppUi.Node {
    const height = pictureHeight(note);
    const image_id = note.media_id();
    // Previews off and this one not asked for: a quiet line saying what is there
    // and what pressing it costs, not a box of reserved space for a picture that
    // is not coming.
    if (!g_media_previews and !isMediaAsked(note.id) and image_id == 0) return pictureAskChip(ui, note);
    if (image_id == 0) {
        // The same box the picture will fill, striped: reserved space, not an
        // empty frame, and not a skeleton either, which reads as a row of text
        // still loading rather than as a photograph.
        return pictureBox(ui, note, height, pictureBlur(ui, note, height));
    }
    var picture = ui.image(.{ .image = image_id, .grow = 1 });
    // `ui.image` leaves the fit at `stretch`, which distorts the picture into
    // whatever box it is given (and worse as the window resizes).
    picture.widget.image_fit = .contain;
    // The picture sits in a pressable row rather than carrying the press
    // itself: an image is a leaf, and the hit target belongs on a container.
    // `quiet_hover` keeps it from washing over on hover like a list row, and the
    // box is sized to the drawn picture so only the picture itself is pressable,
    // not the empty width beside a narrow one.
    //
    // The link role is what puts the pointing hand over it: the engine follows
    // the native convention, where the hand marks a link and ordinary controls
    // keep the arrow, so this is the one role that advertises "clickable".
    return pictureBox(ui, note, height, picture);
}

/// The picture's frame: the reading column at the declared height, with the
/// radius and hairline 11o gives it, whatever is inside it, and the chips laid
/// over the corners. A `data_row` lays children out horizontally, so the chips
/// ride a stack: there is no way to place a child at a point.
fn pictureBox(ui: *AppUi, note: *const Note, height: f32, content: AppUi.Node) AppUi.Node {
    return ui.el(.data_row, .{
        .width = pictureWidth(note),
        .height = height,
        .padding = 0,
        .style = .{ .quiet_hover = true, .radius = picture_radius, .border = theme.palette.border_hairline, .stroke_width = 1 },
        .on_press = Msg{ .expand_image = note.id },
        .semantics = .{ .role = .link, .label = "Attached image, press to enlarge", .focusable = true },
    }, .{
        ui.stack(.{ .grow = 1 }, .{
            content,
            pictureChips(ui, note),
        }),
    });
}

/// What a picture is while previews are off: one quiet chip naming it and its
/// weight, which loads that one when pressed. The weight is the note's own claim
/// and may be missing, in which case the chip does not invent one.
fn pictureAskChip(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const label = if (note.image_bytes > 0)
        ui.fmt("image · {s} · load", .{byteSize(ui.arena, note.image_bytes)})
    else
        "image · load";
    return ui.row(.{ .gap = 0 }, .{
        ui.el(.list_item, .{
            .padding = 0.01,
            .height = picture_ask_height,
            .cross = .center,
            .on_press = Msg{ .load_image = note.id },
            .style = .{ .background = p.surface_inset, .border = p.border_chip, .radius = 6, .stroke_width = 1 },
            .semantics = .{ .role = .button, .label = "Load this image", .focusable = true },
        }, .{
            hgap(ui, 9),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_muted } },
                &.{.{ .text = label, .monospace = true, .scale = mono_meta_scale }},
            ),
            hgap(ui, 9),
        }),
        ui.spacer(1),
    });
}

/// A decoded blurhash: the low-frequency colour of a picture, which is all a
/// blurhash carries. Drawn as a grid of flat cells rather than an image, because
/// every one of the runtime's sixteen image slots is already spent on faces and
/// photographs, and a placeholder must not evict the thing it is standing in for.
pub const Blur = struct {
    /// Row-major, `cells_x * cells_y` colours.
    cells: [blur_cells_x * blur_cells_y]canvas.Color = undefined,
    ok: bool = false,
};

/// Deliberately coarse. Every cell is a widget node, and a view past 1024 nodes
/// is REFUSED WHOLE, not degraded: six loading pictures at 8x6 came to 797 nodes
/// on their own, and a wider window mounting nine rows crossed the ceiling and
/// blanked the feed. A blurhash carries only low frequencies, so 4x3 shows what
/// it has for 19 nodes instead of 55.
const blur_cells_x = 4;
const blur_cells_y = 3;

/// blurhash's own alphabet.
fn base83(c: u8) ?f32 {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";
    const i = std.mem.indexOfScalar(u8, alphabet, c) orelse return null;
    return @floatFromInt(i);
}

fn base83Value(hash: []const u8, from: usize, len: usize) ?f32 {
    if (from + len > hash.len) return null;
    var value: f32 = 0;
    for (hash[from .. from + len]) |c| {
        const digit = base83(c) orelse return null;
        value = value * 83 + digit;
    }
    return value;
}

/// sRGB companding, the two halves of it the format needs.
fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// Decodes a blurhash into a small grid of colours. The format is a handful of
/// cosine components; sampling them at each cell's centre is the same sum the
/// reference decoder runs per pixel, at the resolution the eye gets from a
/// placeholder anyway.
pub fn decodeBlurhash(hash: []const u8) Blur {
    var out: Blur = .{};
    if (hash.len < 6) return out;
    const size_flag = base83Value(hash, 0, 1) orelse return out;
    const comp_x: usize = @intFromFloat(@mod(size_flag, 9) + 1);
    const comp_y: usize = @intFromFloat(@floor(size_flag / 9) + 1);
    if (hash.len != 4 + 2 * comp_x * comp_y) return out;

    const quant_max = base83Value(hash, 1, 1) orelse return out;
    const max_ac = (quant_max + 1) / 166.0;

    // The DC term is the average colour, straight sRGB bytes.
    const dc = base83Value(hash, 2, 4) orelse return out;
    const dc_int: u32 = @intFromFloat(dc);
    var colours: [9 * 9][3]f32 = undefined;
    colours[0] = .{
        srgbToLinear(@as(f32, @floatFromInt((dc_int >> 16) & 255)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt((dc_int >> 8) & 255)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(dc_int & 255)) / 255.0),
    };

    var i: usize = 1;
    while (i < comp_x * comp_y) : (i += 1) {
        const ac = base83Value(hash, 4 + i * 2, 2) orelse return out;
        const ac_int: u32 = @intFromFloat(ac);
        colours[i] = .{
            signPow((@as(f32, @floatFromInt(ac_int / (19 * 19))) - 9) / 9, 2.0) * max_ac,
            signPow((@as(f32, @floatFromInt((ac_int / 19) % 19)) - 9) / 9, 2.0) * max_ac,
            signPow((@as(f32, @floatFromInt(ac_int % 19)) - 9) / 9, 2.0) * max_ac,
        };
    }

    for (0..blur_cells_y) |cy| {
        for (0..blur_cells_x) |cx| {
            // The centre of the cell, in the 0..1 the basis is defined over.
            const x = (@as(f32, @floatFromInt(cx)) + 0.5) / @as(f32, @floatFromInt(blur_cells_x));
            const y = (@as(f32, @floatFromInt(cy)) + 0.5) / @as(f32, @floatFromInt(blur_cells_y));
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            for (0..comp_y) |j| {
                for (0..comp_x) |k| {
                    const basis = @cos(std.math.pi * x * @as(f32, @floatFromInt(k))) *
                        @cos(std.math.pi * y * @as(f32, @floatFromInt(j)));
                    const c = colours[j * comp_x + k];
                    r += c[0] * basis;
                    g += c[1] * basis;
                    b += c[2] * basis;
                }
            }
            out.cells[cy * blur_cells_x + cx] = canvas.Color.rgba8(
                @intFromFloat(linearToSrgb(r) * 255 + 0.5),
                @intFromFloat(linearToSrgb(g) * 255 + 0.5),
                @intFromFloat(linearToSrgb(b) * 255 + 0.5),
                255,
            );
        }
    }
    out.ok = true;
    return out;
}

fn signPow(value: f32, exp: f32) f32 {
    const magnitude = std.math.pow(f32, @abs(value), exp);
    return if (value < 0) -magnitude else magnitude;
}

/// What a picture that has not arrived looks like: its own colours when the note
/// carries a blurhash, stripes when it does not.
fn pictureBlur(ui: *AppUi, note: *const Note, height: f32) AppUi.Node {
    const hash = note.imageBlurhash();
    if (hash.len == 0) return pictureStripes(ui, height);
    const blur = decodeBlurhash(hash);
    if (!blur.ok) return pictureStripes(ui, height);

    // Flat cells, not an image: the runtime has sixteen image slots and they are
    // all spent on faces and photographs, so a placeholder must not evict the
    // thing it stands in for. A blurhash carries only low frequencies anyway,
    // which is what a grid of them shows.
    const rows = ui.arena.alloc(AppUi.Node, blur_cells_y) catch return pictureStripes(ui, height);
    for (rows, 0..) |*row, y| {
        const cells = ui.arena.alloc(AppUi.Node, blur_cells_x) catch return pictureStripes(ui, height);
        for (cells, 0..) |*cell, x| {
            cell.* = ui.el(.panel, .{
                .grow = 1,
                .padding = 0.01,
                .style = .{ .background = blur.cells[y * blur_cells_x + x], .radius = 0, .stroke_width = 0 },
            }, .{});
        }
        row.* = ui.row(.{ .grow = 1, .gap = 0 }, .{cells});
    }
    return ui.column(.{ .grow = 1, .gap = 0 }, .{rows});
}

/// The fill under a picture that has not arrived. The shot draws 45 degree
/// stripes; the canvas has no gradients at the widget level and no rotation, so
/// they run flat, which keeps what the stripes are FOR (this is a photograph
/// arriving, not a paragraph) without pretending to an angle.
fn pictureStripes(ui: *AppUi, height: f32) AppUi.Node {
    const p = theme.palette;
    // The band count is capped, so the BANDS grow instead: a stated height that
    // stopped at the cap left the bottom of a tall box as bare window inside its
    // own border.
    const count: usize = @min(@max(1, @as(usize, @intFromFloat(@ceil(height / 14)))), picture_stripe_cap);
    const bands = ui.arena.alloc(AppUi.Node, count) catch return ui.spacer(0);
    for (bands, 0..) |*b, i| {
        b.* = ui.el(.panel, .{
            .grow = 1,
            .padding = 0.01,
            .style = .{ .background = if (i % 2 == 0) p.surface_stripe_a else p.surface_stripe_b, .radius = 0, .stroke_width = 0 },
        }, .{});
    }
    return ui.column(.{ .grow = 1, .gap = 0 }, .{bands});
}

/// 11o's link preview: what the page on the other end says it is. One per note,
/// under the body, and the URL stays in the text as well, because the card is a
/// courtesy and the address is the fact.
///
/// The tile is a letter, never a favicon: a favicon would want one of the
/// sixteen image slots the whole runtime has, and those belong to faces and
/// photographs.
fn linkCard(ui: *AppUi, note: *const Note) AppUi.Node {
    const p = theme.palette;
    const url = note.linkUrl();
    const entry = linkFor(url);
    // Nothing to show until the page has answered. No skeleton: a card that
    // might never come is worse than a link that reads as a link.
    if (entry == null or entry.?.state != .loaded) return ui.spacer(0);
    const link = entry.?;
    const initial = std.ascii.toUpper(if (link.domain().len > 0) link.domain()[0] else '?');

    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 3),
        ui.el(.list_item, .{
            .width = picture_column_width,
            .padding = 0.01,
            // The URL slice lives in the note, which lives in the model, and the
            // opener copies it before it runs.
            .on_press = Msg{ .open_url = url },
            .style = .{ .background = p.surface_link_card, .border = p.border_chip_alt, .radius = 10, .stroke_width = 1 },
            .semantics = .{ .role = .link, .label = "Open link", .focusable = true },
        }, .{
            hgap(ui, 12),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 10),
                ui.el(.panel, .{
                    .width = 30,
                    .height = 30,
                    .padding = 0.01,
                    .style = .{ .background = p.surface_link_tile, .radius = 7, .stroke_width = 0 },
                }, .{
                    ui.column(.{ .width = 30, .height = 30, .main = .center, .cross = .center }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = ui.fmt("{c}", .{initial}), .monospace = true, .weight = .medium, .scale = meta_scale }},
                        ),
                    }),
                }),
            }),
            hgap(ui, 10),
            ui.column(.{ .grow = 1, .gap = 0 }, .{
                vgap(ui, 10),
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_dim } },
                    &.{.{ .text = link.domain(), .monospace = true, .scale = mono_chip_scale }},
                ),
                vgap(ui, 2),
                ui.text(.{
                    .wrap = false,
                    .overflow = .ellipsis,
                    .grow = 1,
                    .size = .sm,
                    .style = .{ .foreground = p.text_link_title },
                }, link.title()),
                if (link.description().len == 0) ui.spacer(0) else vgap(ui, 2),
                if (link.description().len == 0) ui.spacer(0) else ui.paragraph(.{
                    .wrap = false,
                    .overflow = .ellipsis,
                    .grow = 1,
                    .style = .{ .foreground = p.text_muted },
                }, &.{.{ .text = link.description(), .scale = mono_row_scale }}),
                vgap(ui, 10),
            }),
            hgap(ui, 12),
        }),
    });
}

/// The two chips 11o lays over a picture: its declared size at the top right and
/// its alt text at the bottom left. Both read at rest, because hover cannot
/// restyle or reveal a child.
fn pictureChips(ui: *AppUi, note: *const Note) AppUi.Node {
    const dims = note.imageChipLabel(ui.arena);
    const alt = note.image_has_alt;
    if (dims.len == 0 and !alt) return ui.spacer(0);
    return ui.column(.{ .grow = 1, .gap = 0 }, .{
        ui.row(.{ .grow = 1, .main = .end, .cross = .start, .gap = 0 }, .{
            if (dims.len == 0) ui.spacer(0) else pictureChip(ui, dims, false),
            hgap(ui, picture_chip_inset),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, picture_chip_inset),
            if (!alt) ui.spacer(0) else pictureChip(ui, "ALT", true),
            ui.spacer(1),
        }),
        vgap(ui, picture_chip_inset),
    });
}

/// One chip over a picture: mono, small, on a scrim dark enough to read against
/// any photograph.
fn pictureChip(ui: *AppUi, label: []const u8, emphatic: bool) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, picture_chip_inset),
        ui.el(.panel, .{
            .padding = 0.01,
            .height = picture_chip_height,
            .style = .{ .background = p.scrim_chip, .border = p.border_chip_alt, .radius = 5, .stroke_width = 1 },
        }, .{
            ui.row(.{ .cross = .center, .gap = 0 }, .{
                hgap(ui, 7),
                // A scaled span, because the 10px mono register has no size enum
                // rung. No stated width: 11o draws both of these as pills hugging
                // their text, and a fixed one made "ALT" a 194px bar across the
                // bottom of every described picture. Both labels are bounded by
                // construction, the longest being `1600×900 · 240 KB`.
                ui.paragraph(.{
                    .wrap = false,
                    .style = .{ .foreground = if (emphatic) p.text_secondary else p.text_muted_alt },
                }, &.{.{
                    .text = label,
                    .monospace = true,
                    .weight = if (emphatic) .medium else .regular,
                    .scale = mono_chip_scale,
                }}),
                hgap(ui, 7),
            }),
        }),
    });
}

/// How wide the drawn picture is: its own shape at the reserved height, never
/// wider than the card. `contain` centres a narrow picture in its box, so
/// matching the box to the picture is what keeps the press on the picture.
pub fn pictureWidth(note: *const Note) f32 {
    // The TRUE aspect, not the capped one: a picture taller than the cap is
    // drawn `contain`ed at the reserved height, so its drawn width is what the
    // shape says, and the box must be that or the gutters either side are bare
    // window inside the border, and pressable.
    const aspect = pictureAspect(note);
    if (aspect <= 0) return picture_column_width;
    // The box IS the picture: a portrait photo drawn `contain`ed inside a
    // column-wide box would leave bare window either side, inside the border,
    // and all of it pressable. Matching the box to what is drawn keeps the press
    // on the picture and the chips on its corners.
    return @min(picture_column_width, pictureHeight(note) / aspect);
}

const PlazaApp = native_sdk.UiApp(Model, Msg);

/// The keyboard, as the shell delivers it: a shortcut declared in the manifest
/// arrives here by id and becomes an ordinary message, so a key does exactly
/// what the control it stands for does, and never a second implementation of it.
///
/// What each one means depends on what is open, and that is decided in `update`
/// where the model is, not here: this only names the intent.
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "new-note")) return .open_compose;
    if (std.mem.eql(u8, name, "post-note")) return .post;
    if (std.mem.eql(u8, name, "settings")) return .open_settings;
    if (std.mem.eql(u8, name, "dismiss")) return .dismiss_top;
    return null;
}
const Effects = PlazaApp.Effects;
/// The effects type, exported so tests can exercise the fx-free slot paths.
pub const EffectsForTest = Effects;

/// Boot: seed the feed once, register whatever images are already cached, then
/// arm the repeating timers.
pub fn boot(model: *Model, fx: *Effects) void {
    model.refresh(nowSeconds());
    // What was written but not sent when the app last closed, back in the
    // composer where it was left.
    var draft_buf: [note_content_cap]u8 = undefined;
    const stashed = loadDraft(&draft_buf);
    if (stashed.len > 0) model.draft_buffer = @TypeOf(model.draft_buffer).init(stashed);
    // What was owed when the app last closed. Read before the first frame, so a
    // note written offline yesterday is visible as owed rather than lost, and
    // offered again as soon as a relay answers.
    loadOutbox();
    // Local-first, all the way to the first frame: cached avatars and pictures
    // are registered here, so a returning user gets faces WITH the notes rather
    // than a tick later. Only what is on disk resolves now; the rest is fetched
    // from the first tick onward.
    assignAvatarSlots(fx, model);
    scanAvatarFetches(fx);
    scanMediaFetches(fx, model);
    scanLinkFetches(fx, model);
    scanNip05Fetches(fx);
    fx.startTimer(.{
        .key = refresh_timer_key,
        .interval_ms = refresh_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    // One timer drives every playing GIF; a timer each would exhaust the table.
    fx.startTimer(.{
        .key = animation_timer_key,
        .interval_ms = animation_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.animate),
    });
    // Bring up the isolated signer; the tick health-checks it until it answers.
    spawnHelper(fx);
    // Background metadata fetching on its own cadence, off the view refresh.
    fx.startTimer(.{
        .key = profile_timer_key,
        .interval_ms = profile_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.profiles),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick => |t| {
            if (t.outcome == .fired) {
                const now = nowSeconds();
                model.refresh(now);
                // Keep the open thread's replies current: late replies appear and
                // relative times stay fresh, the same cadence as the feed.
                model.refreshThreadNotes(now);
                // Anything still owed goes back out whenever a relay is up: this
                // is the drain, and it is idempotent, since an entry already in
                // flight is skipped.
                if (liveRelayCount() > 0) drainOutbox(std.heap.page_allocator);
                sweepOutbox(now);
                const counts = outboxCounts();
                model.outbox_pending = counts.trying;
                model.outbox_stuck = counts.stuck;
                if (g_outbox_rev.load(.monotonic) != g_outbox_saved_rev) {
                    g_outbox_saved_rev = g_outbox_rev.load(.monotonic);
                    saveOutbox();
                }
                // Start any pending image fetches (needs effects, so here, not
                // in refresh). The feed reads loaded images at render time.
                assignAvatarSlots(fx, model);
                scanAvatarFetches(fx);
                scanMediaFetches(fx, model);
                scanLinkFetches(fx, model);
                scanNip05Fetches(fx);
                // Complete a like a guest reached for, now that they have signed
                // in and the feed above has rebuilt.
                drivePendingLike(model, fx);
                // Retire timed-out or refused signer requests, restoring a lost
                // draft to the composer (this thread owns it).
                if (g_signer_kind == .remote) scanPendingRemote(model);
                // Health-check the signer daemon until the loopback IPC answers,
                // then fire any queued key setup.
                pollHelper(fx);
                driveHelperSetup(fx);
                // A toast lives a few seconds, then the tick retires it.
                if (model.toast_until != 0 and nowSeconds() >= model.toast_until) {
                    model.toast_until = 0;
                    model.toast_len = 0;
                }
            }
        },
        .animate => |t| {
            if (t.outcome == .fired) advanceAnimations(fx, model);
        },
        .profiles => |t| {
            if (t.outcome == .fired) {
                // Re-arm the still-unnamed every so often: a relay that had
                // nothing a moment ago may have it now.
                g_profile_round +%= 1;
                if (g_profile_round % profile_rearm_rounds == 0) {
                    rearmWantedProfiles();
                    rearmWantedQuotes();
                }
                requestWantedProfiles();
                requestWantedQuotes();
            }
        },
        .helper_exited => |e| {
            if (e.reason != .exited) std.debug.print("plaza: [helper] exited\n", .{});
        },
        .helper_pubkey => |response| {
            handleHelperPubkey(model, response);
            // A queued setup fires the moment the daemon is reachable.
            driveHelperSetup(fx);
        },
        .helper_setup => |response| handleHelperSetup(model, response),
        .helper_signed => |response| handleHelperSigned(response),
        .avatar_fetched => |response| handleAvatarFetched(fx, response),
        .draft_edit => |edit| {
            model.draft_buffer.apply(edit);
            // The user is composing again: retire a stale "signer didn't respond".
            g_remote_sign_notice.store(false, .release);
        },
        .post => {
            // A KEY can reach this where the button could not: the button is
            // disabled on an empty draft, so until Cmd+Enter existed this
            // message never arrived with nothing to send. Closing the sheet and
            // saying "Posted" over an empty composer would be the plainest lie
            // in the app.
            if (model.draft_empty()) return;
            submitPost(model, fx);
            // Posting closes the sheet; the note is already local and will
            // appear on the next tick.
            model.composing = false;
            setToast(model, if (g_signer_kind == .remote) "Sent to your signer" else "Posted");
            // The first local post is the calm moment to suggest a backup.
            if (g_signer_kind == .local and !model.backup_nudge_dismissed)
                model.backup_nudge = true;
        },
        .open_compose => {
            // The gate is on press, not on sight: a guest reaching for the
            // composer is exactly first intent, so the sheet rises and
            // remembers what was reached for.
            if (model.is_guest()) {
                model.joining = true;
                model.pending_compose = true;
            } else model.composing = true;
        },
        .dismiss_top => {
            // Topmost first: a menu over a sheet over a thread. Each press
            // closes exactly one thing, which is what makes the key learnable.
            if (model.menu != .none) {
                model.menu = .none;
            } else if (model.expanded_note != 0) {
                model.expanded_note = 0;
            } else if (model.composing) {
                model.composing = false;
                saveDraft(model.draft());
            } else if (model.joining) {
                model.joining = false;
            } else if (model.stage == .settings) {
                model.logout_pending = false;
                model.reveal_nsec = false;
                model.stage = .ready;
            } else if (model.viewing_thread != 0) {
                closeThread(model);
            }
        },
        .insert_mention => |pubkey| insertMention(model, pubkey),
        .close_compose => {
            model.composing = false;
            // Closing the sheet stashes what is in it. The words survived a
            // closed sheet already; this is what carries them past a quit.
            saveDraft(model.draft());
        },
        .open_join => model.joining = true,
        .close_join => {
            model.joining = false;
            model.bunker_mode = false;
            model.pending_compose = false;
            model.pending_like = 0;
        },
        .join_create => {
            // Async: the daemon mints the key (the key never enters Plaza), the
            // response adopts the identity and opens the name beat.
            model.joining = false;
            queueHelperSetup(fx, .create, null);
        },
        .open_signet_import => {
            // Key material never enters Plaza: the Signet window takes the
            // paste and hands it to the daemon; Plaza signs in when the key
            // appears (handleHelperPubkey). If the window binary is missing,
            // fall back to the in-Plaza field rather than a dead button.
            model.joining = false;
            if (g_signet_win_len > 0) spawnSignetWindow(fx) else model.stage = .onboarding;
        },
        .keep_browsing => {
            model.stage = .ready;
            model.pending_compose = false;
        },
        .open_bunker => model.bunker_mode = true,
        .close_bunker => {
            model.bunker_mode = false;
            model.login_buffer.clear();
            g_login_error.store(@intFromEnum(LoginError.none), .release);
        },
        .dismiss_guest_strip => model.guest_strip_dismissed = true,
        // A trigger toggles its own menu and replaces any other, so the chrome
        // never shows two floating surfaces at once.
        .toggle_menu => |which| model.menu = if (model.menu == which) .none else which,
        .close_menu => model.menu = .none,
        .toggle_relays_paused => {
            model.relays_paused = !model.relays_paused;
            setRelaysPaused(model.relays_paused);
            model.menu = .none;
        },
        // The feed's own list holds the scroll, and there is no API to set an
        // offset, so "newest" is the reconcile that puts the newest note back at
        // the top: the same thing the tick does, asked for on purpose.
        // There is no API to set a list's scroll offset, so this cannot scroll
        // the feed. What it CAN do is make sure nothing is stale before the
        // reader looks: force the next tick to rebuild from the store.
        .show_more_replies => model.thread_page[model.currentLevel()] += 1,
        .toggle_outside_replies => {
            const level = model.currentLevel();
            model.thread_outside_open[level] = !model.thread_outside_open[level];
        },
        .jump_to_newest => {
            g_last_count = std.math.maxInt(usize);
            model.menu = .none;
        },
        .copy_nevent => |id| {
            const note = model.noteById(id) orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const addr = nostr.nip19.encodeNevent(fba.allocator(), note.event_id, &.{}, note.pubkey, 1) catch return;
            fx.writeClipboard(.{ .key = copy_nevent_key, .text = addr });
            setToast(model, "Address copied");
        },
        // njump renders any nostr event as a web page, which is how a note is
        // shared with someone who is not on nostr yet.
        .open_web => |id| {
            const note = model.noteById(id) orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const addr = nostr.nip19.encodeNevent(fba.allocator(), note.event_id, &.{}, note.pubkey, 1) catch return;
            var url_buf: [256]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://njump.me/{s}", .{addr}) catch return;
            openExternally(fx, url);
        },
        .open_settings_logout => {
            model.menu = .none;
            model.logout_pending = true;
            update(model, .open_settings, fx);
        },
        .name_edit => |edit| model.name_buffer.apply(edit),
        .name_save => {
            publishName(model, fx);
            model.naming = false;
            setToast(model, "Name set");
            replayPending(model);
        },
        .name_skip => {
            model.naming = false;
            replayPending(model);
        },
        .backup_now => {
            model.backup_nudge = false;
            model.backup_nudge_dismissed = true;
            model.stage = .settings;
        },
        .backup_later => {
            model.backup_nudge = false;
            model.backup_nudge_dismissed = true;
        },
        .create_identity => queueHelperSetup(fx, .create, null),
        .login_edit => |edit| model.login_buffer.apply(edit),
        .login_submit => {
            g_login_error.store(@intFromEnum(LoginError.none), .release);
            const raw = std.mem.trim(u8, model.login_buffer.text(), " \t\r\n");
            switch (classifyLogin(raw)) {
                // Import an existing key: it lands on disk (0600) as the local
                // identity. A bad nsec keeps us on onboarding with an error.
                .nsec => {
                    if (!importNsec(raw)) return;
                    persistSession();
                    // Tolerate an nsec pasted into the bunker step: close the
                    // sheet the same way the bunker success path does.
                    model.joining = false;
                    model.bunker_mode = false;
                    enterFeed(model);
                    replayPending(model);
                },
                // Pair with the external signer from the bunker URL; on success
                // the feed comes up and posts route through it. A bad URL keeps
                // us on onboarding with an error (see `login_status`).
                .bunker => {
                    if (!connectRemoteSigner(raw)) return;
                    persistSession();
                    // The connection is optimistic: land in the feed at once
                    // (the composer line shows reaching/connected), close the
                    // sheet, and reset the bunker step.
                    model.joining = false;
                    model.bunker_mode = false;
                    enterFeed(model);
                    replayPending(model);
                },
                .invalid => g_login_error.store(@intFromEnum(LoginError.format), .release),
            }
        },
        .open_settings => {
            model.menu = .none;
            // Seed the proxy field from the live setting so it edits in place.
            model.proxy_buffer.set(mediaProxy());
            model.proxy_saved = false;
            model.stage = .settings;
        },
        .proxy_edit => |edit| {
            model.proxy_buffer.apply(edit);
            model.proxy_saved = false;
        },
        .proxy_save => {
            setMediaProxy(model.proxy_buffer.text());
            saveSettings();
            model.proxy_saved = true;
            // Retry anything that failed to load under the previous setting.
            retryFailedImages();
        },
        .previews_toggle => {
            setMediaPreviews(!mediaPreviews());
            saveSettings();
            // Turning it back on should fill the feed in without a restart.
            if (mediaPreviews()) {
                retryFailedImages();
                scanAvatarFetches(fx);
                scanMediaFetches(fx, model);
                scanLinkFetches(fx, model);
            }
        },
        .media_fetched => |response| handleMediaFetched(fx, response),
        .nip05_verified => |response| handleNip05Fetched(response),
        .link_fetched => |response| handleLinkFetched(response),
        .open_url => |url| openExternally(fx, url),
        .expand_image => |note_id| model.expanded_note = note_id,
        .load_image => |note_id| {
            askForMedia(note_id);
            scanMediaFetches(fx, model);
        },
        .close_image => model.expanded_note = null,
        .like => |note_id| toggleLike(model, fx, note_id),
        .open_thread => |note_id| openThread(model, note_id),
        .open_event => |id| openEvent(model, id),
        .close_thread => closeThread(model),
        .reply_edit => |edit| model.reply_buffer.apply(edit),
        .reply_submit => publishReply(model, fx),
        .toggle_expand => |note_id| toggleExpanded(note_id),
        .feed_scrolled => |scroll| {
            model.feed_scroll = scroll;
            // Load what just came into view without waiting for the next tick:
            // hand avatar ids to the newly-visible authors, then their faces and
            // pictures.
            assignAvatarSlots(fx, model);
            scanAvatarFetches(fx);
            scanMediaFetches(fx, model);
            scanLinkFetches(fx, model);
        },
        .load_older => {
            // One more page from the store, up to what the feed can hold.
            if (model.feed_limit >= feed_capacity) return;
            model.feed_limit = @min(model.feed_limit + feed_page, feed_capacity);
            g_last_count = std.math.maxInt(usize);
            model.refresh(nowSeconds());
        },
        .close_settings => {
            model.logout_pending = false;
            model.reveal_nsec = false;
            model.stage = .ready;
        },
        .toggle_nsec => model.reveal_nsec = !model.reveal_nsec,
        .copy_npub => {
            const pk = activePubkey() orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const npub = nostr.nip19.encodeNpub(fba.allocator(), pk) catch return;
            fx.writeClipboard(.{ .key = copy_npub_key, .text = npub });
        },
        .copy_nsec => {
            if (g_signer_kind != .local) return;
            const kp = g_identity_kp orelse return;
            var scratch: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&scratch);
            const nsec = nostr.nip19.encodeNsec(fba.allocator(), kp.secret_key) catch return;
            fx.writeClipboard(.{ .key = copy_nsec_key, .text = nsec });
        },
        .logout_request => model.logout_pending = true,
        .logout_cancel => model.logout_pending = false,
        .logout_confirm => performLogout(model, fx),
    }
}

/// Switches to the feed and brings the store + ingest pool up if they are not
/// already running. Shared by all sign-in paths (create, import, remote signer).
/// A fresh identity means the feed's author filter changed, so force a rebuild
/// on the next tick by invalidating the change guard.
/// Shows a small confirming toast for a few seconds (the tick retires it).
fn setToast(model: *Model, text: []const u8) void {
    const n = @min(text.len, model.toast_buf.len);
    @memcpy(model.toast_buf[0..n], text[0..n]);
    model.toast_len = n;
    model.toast_until = nowSeconds() + 3;
}

/// Publishes the name beat's text as the account's kind:0 metadata, and seeds
/// the local profile cache so the app shows the name at once. Local keys only
/// (the beat never runs for imports or signers). Quotes and backslashes are
/// dropped rather than escaped: a display name is prose, not JSON.
fn publishName(model: *Model, fx: *Effects) void {
    const raw = std.mem.trim(u8, model.name_buffer.text(), " \t\r\n");
    if (raw.len == 0) return;
    const signer = g_identity_signer orelse return;
    const kp = g_identity_kp orelse return;
    const gpa = std.heap.page_allocator;

    var clean_buf: [64]u8 = undefined;
    var clean_len: usize = 0;
    for (raw) |c| {
        if (c == '"' or c == '\\') continue;
        clean_buf[clean_len] = c;
        clean_len += 1;
    }
    const clean = clean_buf[0..clean_len];
    if (clean.len == 0) return;

    const json = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{clean}) catch return;
    if (g_signer_kind == .helper) {
        // The daemon signs the kind:0; the response seeds the cache.
        requestHelperSign(fx, gpa, nowSeconds(), 0, &.{}, json);
        model.name_buffer.clear();
        return;
    }
    const ev = nostr.event.create(gpa, signer, kp, nowSeconds(), 0, &.{}, json, null) catch {
        gpa.free(json);
        return;
    };
    ingestAndPublish(gpa, ev, null);
    // Seed the cache: the composer line and the feed show the name at once.
    if (upsertProfile(kp.public_key)) |prof| parseMetadataInto(prof, json);
    model.name_buffer.clear();
}

/// Completes the remembered first intent once an identity exists: the guest
/// reached for the composer, so it opens by itself. The welcome-in moment.
fn replayPending(model: *Model) void {
    if (model.pending_compose) {
        model.pending_compose = false;
        model.composing = true;
    }
}

/// The replay seam, exercised without disk or relays. For tests.
pub fn replayPendingForTest(model: *Model) void {
    replayPending(model);
}

/// Restores a helper identity from a session pubkey hex. For tests.
pub fn restoreHelperForTest(pubkey_hex: []const u8) bool {
    return restoreHelperIdentity(pubkey_hex);
}

/// Drives the remote-signer connection state (0 idle, 1 reaching, 2 connected,
/// 3 unreachable) plus a remote identity, so the presentation is testable
/// without a live bunker. For tests.
pub fn setRemoteStateForTest(status: u8, npub_len: usize) void {
    g_signer_kind = if (status == 0) .local else .remote;
    g_remote_status.store(status, .release);
    g_remote_sign_notice.store(false, .release);
    if (npub_len > 0) {
        const stub = "npub1testsigner";
        const n = @min(stub.len, g_identity_npub_buf.len);
        @memcpy(g_identity_npub_buf[0..n], stub[0..n]);
        g_identity_npub_len = n;
    } else g_identity_npub_len = 0;
}

fn enterFeed(model: *Model) void {
    model.stage = .ready;
    g_last_count = std.math.maxInt(usize);
    if (g_store == null) {
        if (g_io) |io| if (g_environ) |env| startFeed(io, env);
    }
}

pub fn initialModel() Model {
    return .{};
}

// -------------------------------------------------------------- compose & post
//
// Posting is local-first: a composed note is signed, written to the local store
// straight away (so it shows in the feed on the next tick), and published to the
// pool on a detached thread. The feed dedupes by event id, so when a relay later
// echoes our own note back through the ingest subscriptions it collapses onto
// the local copy.

/// Posts the current draft: sign a kind:1 note, store it locally at once, and
/// publish it to the pool in the background. A blank draft or a not-yet-ready
/// identity is a no-op.
fn submitPost(model: *Model, fx: *Effects) void {
    const text = std.mem.trim(u8, model.draft_buffer.text(), " \t\r\n");
    if (text.len == 0) return;
    const gpa = std.heap.page_allocator;

    // A process-lifetime copy of the content: `event.create` references its
    // content slice rather than copying it, and the store write and either the
    // publisher or the NIP-46 round-trip read it after the draft is cleared.
    const owned = gpa.dupe(u8, text) catch return;
    // A composer draft: kind:1, no tags, restorable to the composer if a remote
    // signer never answers.
    signAndPublish(fx, gpa, nowSeconds(), 1, &.{}, owned, true);
    model.draft_buffer.clear();
}

/// Signs `content_owned` as an event of `kind` with `tags`, stamped `created`,
/// through whichever signer is active, then stores and publishes it. Takes
/// ownership of `content_owned` and `tags` (process-lifetime: the local and
/// remote paths reference them after this returns, and the write seam intends
/// them to outlive the detached publish). `restorable` marks a composer draft,
/// so only a lost post is put back in the composer, never a reaction.
fn signAndPublish(fx: *Effects, gpa: std.mem.Allocator, created: i64, kind: u16, tags: []const nostr.event.Tag, content_owned: []const u8, restorable: bool) void {
    switch (g_signer_kind) {
        .local => {
            const signer = g_identity_signer orelse return;
            const kp = g_identity_kp orelse return;
            const ev = nostr.event.create(gpa, signer, kp, created, kind, tags, content_owned, null) catch return;
            ingestAndPublish(gpa, ev, null);
        },
        .remote => requestRemoteSign(gpa, created, kind, tags, content_owned, restorable),
        .helper => requestHelperSign(fx, gpa, created, kind, tags, content_owned),
    }
}

/// Publishes the reply composer's text as a NIP-10 reply to the open thread's
/// note: a kind:1 e-tagging the root (marked "root") and p-tagging its author,
/// signed and stored local-first so it joins the thread at once. A guest cannot
/// sign, so a reply attempt routes to the join sheet.
fn publishReply(model: *Model, fx: *Effects) void {
    if (model.viewing_thread == 0) return;
    if (model.is_guest()) {
        model.joining = true;
        return;
    }
    const root = model.noteById(model.viewing_thread) orelse return;
    const text = std.mem.trim(u8, model.reply_buffer.text(), " \t\r\n");
    if (text.len == 0) return;
    const gpa = std.heap.page_allocator;
    const content = gpa.dupe(u8, text) catch return;
    const id_hex = hexAlloc(gpa, root.event_id) orelse return;
    const author_hex = hexAlloc(gpa, root.pubkey) orelse return;
    const e_tag = gpa.dupe([]const u8, &.{ "e", id_hex, "", "root" }) catch return;
    const p_tag = gpa.dupe([]const u8, &.{ "p", author_hex }) catch return;
    const tags = gpa.alloc(nostr.event.Tag, 2) catch return;
    tags[0] = e_tag;
    tags[1] = p_tag;
    signAndPublish(fx, gpa, nowSeconds(), 1, tags, content, false);
    model.reply_buffer.clear();
}

// ------------------------------------------------------------------------ likes
//
// A like is a NIP-25 kind:7 reaction with content "+", e/p/k-tagging the note.
// It rides the same three sign paths as a post and is local-first and optimistic:
// the heart fills the instant it is pressed (read from `g_my_likes` at render),
// and the reaction publishes in the background. Un-like is a NIP-09 kind:5
// deletion e-tagging our own reaction, since NIP-25 has no un-react. A guest
// press cannot sign, so it is remembered and completed after sign-in.

/// Lowercase-hex-encodes a 32-byte value into a fresh process-lifetime slice.
fn hexAlloc(gpa: std.mem.Allocator, bytes: [32]u8) ?[]const u8 {
    const out = gpa.alloc(u8, 64) catch return null;
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out;
}

/// The NIP-25 like tags for a note: `["e", id]`, `["p", author]`, `["k", "1"]`.
/// Process-lifetime (the sign paths reference them); null on OOM.
fn buildLikeTags(gpa: std.mem.Allocator, note: *const Note) ?[]const nostr.event.Tag {
    const id_hex = hexAlloc(gpa, note.event_id) orelse return null;
    const author_hex = hexAlloc(gpa, note.pubkey) orelse return null;
    const e = gpa.dupe([]const u8, &.{ "e", id_hex }) catch return null;
    const p = gpa.dupe([]const u8, &.{ "p", author_hex }) catch return null;
    const k = gpa.dupe([]const u8, &.{ "k", "1" }) catch return null;
    const tags = gpa.alloc(nostr.event.Tag, 3) catch return null;
    tags[0] = e;
    tags[1] = p;
    tags[2] = k;
    return tags;
}

/// The NIP-09 deletion tags to un-like: `["e", reaction_id]`, `["k", "7"]`.
fn buildUnlikeTags(gpa: std.mem.Allocator, reaction_id: [32]u8) ?[]const nostr.event.Tag {
    const id_hex = hexAlloc(gpa, reaction_id) orelse return null;
    const e = gpa.dupe([]const u8, &.{ "e", id_hex }) catch return null;
    const k = gpa.dupe([]const u8, &.{ "k", "7" }) catch return null;
    const tags = gpa.alloc(nostr.event.Tag, 2) catch return null;
    tags[0] = e;
    tags[1] = k;
    return tags;
}

/// Toggles a like on `note_id`. A guest cannot sign, so the like is remembered
/// and the join sheet opens; it completes after sign-in (`drivePendingLike`).
fn toggleLike(model: *Model, fx: *Effects, note_id: i64) void {
    if (model.is_guest()) {
        model.pending_like = note_id;
        model.joining = true;
        return;
    }
    if (isLiked(note_id)) unlike(fx, note_id) else like(model, fx, note_id);
}

/// Publishes a kind:7 like and fills the heart at once. The reaction id is
/// deterministic in the unsigned fields, so it is computed here (with the same
/// created/tags/content the sign path will use) and remembered, so an un-like
/// can delete exactly this reaction.
fn like(model: *const Model, fx: *Effects, note_id: i64) void {
    const note = model.noteById(note_id) orelse return;
    const gpa = std.heap.page_allocator;
    const pk = activePubkey() orelse return;
    const created = nowSeconds();
    const tags = buildLikeTags(gpa, note) orelse return;
    const content = gpa.dupe(u8, "+") catch return;
    const id = nostr.event.computeId(gpa, pk, created, 7, tags, content) catch return;
    rememberLike(note_id, id);
    signAndPublish(fx, gpa, created, 7, tags, content, false);
}

/// Publishes a kind:5 deletion of our own reaction and empties the heart at once.
fn unlike(fx: *Effects, note_id: i64) void {
    const gpa = std.heap.page_allocator;
    const reaction_id = forgetLike(note_id) orelse return;
    const tags = buildUnlikeTags(gpa, reaction_id) orelse return;
    const content = gpa.dupe(u8, "") catch return;
    signAndPublish(fx, gpa, nowSeconds(), 5, tags, content, false);
}

/// After sign-in, completes a like a guest reached for: the welcome-in moment.
/// Driven from the tick, where `fx` is in hand and the feed has just rebuilt.
fn drivePendingLike(model: *Model, fx: *Effects) void {
    if (model.pending_like == 0 or model.is_guest()) return;
    const note_id = model.pending_like;
    model.pending_like = 0;
    if (isLiked(note_id)) return;
    like(model, fx, note_id);
    setToast(model, "Liked");
}

/// Deep-copies `tags` into process-lifetime memory so the detached publisher can
/// read them after the parse arena is freed. Returns an empty set on OOM (posts
/// are tagless, so nothing is lost there; a reaction that OOMs simply drops).
fn dupeTags(gpa: std.mem.Allocator, tags: []const nostr.event.Tag) []const nostr.event.Tag {
    if (tags.len == 0) return &.{};
    const out = gpa.alloc(nostr.event.Tag, tags.len) catch return &.{};
    for (tags, 0..) |tag, i| {
        const fields = gpa.alloc([]const u8, tag.len) catch return &.{};
        for (tag, 0..) |field, j| {
            fields[j] = gpa.dupe(u8, field) catch return &.{};
        }
        out[i] = fields;
    }
    return out;
}

/// The engine write seam: a note this process now holds, whether locally signed
/// or returned signed from the remote signer, enters the local store and is
/// published to the pool. The store is the single-writer data plane, only ever
/// written from this process. `verify` re-checks a signature we did not produce
/// ourselves and gates such a note out of both the store and the pool on
/// failure; a note we just signed skips the check and publishes even if the
/// store rejects the write (a duplicate). `ev.content` must be a
/// process-lifetime allocation, since the detached publisher reads it after
/// this returns.
fn ingestAndPublish(gpa: std.mem.Allocator, ev: nostr.event.Event, verify: ?nostr.keys.Signer) void {
    const store = g_store orelse return;
    if (verify) |signer| {
        // A note we did not produce: verification is the gate into the store
        // AND the pool, so a bad signature is dropped rather than propagated.
        _ = store.ingest(gpa, ev, .{ .verify_with = signer }) catch return;
    } else {
        // A note we just signed: a store failure (e.g. a duplicate id) must not
        // stop it reaching the pool.
        _ = store.ingest(gpa, ev, .{}) catch {};
    }
    // Queued BEFORE the walk, so a note that never reaches a relay is still a
    // note the app knows it owes the reader. A queue with no room says so:
    // publishing anyway would be a note nobody is tracking while the banner
    // promises that anything written is kept.
    if (!enqueueOutbox(ev.id, nowSeconds())) {
        g_outbox_overflow.store(true, .monotonic);
        return;
    }
    const thread = std.Thread.spawn(.{}, publishWorker, .{ gpa, ev }) catch {
        // No thread: the note stays queued and the next drain will carry it.
        return;
    };
    thread.detach();
}

/// One publish walk for `ev`, with the queue updated around it.
fn publishWorker(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    markOutboxSending(ev.id, true);
    publishEvent(gpa, ev);
    markOutboxSending(ev.id, false);
}

fn markOutboxSending(id: [32]u8, sending: bool) void {
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return;
    e.sending = sending;
    if (!sending) e.rounds +|= 1;
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

// -------------------------------------------------------------------- the outbox
//
// What happens to a note between pressing Post and knowing it is somewhere else.
//
// Publishing used to be fire-and-forget: a detached thread dialled every relay,
// wrote the frame, read one message to flush it, and dropped the verdict. The
// note was in the local store, so the feed showed it, and whether it ever
// reached anyone was not a question the app could answer.
//
// Now every publish goes through a queue. Each entry names an event that is
// already in the store's own tables (we ingest what we sign) and carries one bit
// per relay: did that relay say OK. The queue is the app's answer to "is my note
// out there", the status bar reads it, and it survives a quit, because a note
// written on a train and lost on landing is the worst thing a client can do.
//
// The queue is small on purpose. It is not a retry engine for a broken network;
// it is a record of what has not been acknowledged yet, drained whenever a relay
// comes back.

/// One note on its way out.
pub const OutboxEntry = struct {
    used: bool = false,
    id: [32]u8 = [_]u8{0} ** 32,
    /// When it was queued, so the popover can say how long it has been waiting
    /// and the oldest entry can be dropped when the queue is full.
    queued_at: i64 = 0,
    /// One bit per pool relay: this relay answered OK.
    acked: u8 = 0,
    /// One bit per pool relay: this relay answered, and said no.
    refused: u8 = 0,
    /// How many times the publisher has walked the relays for this entry, so a
    /// note nobody will take stops asking rather than hammering forever.
    rounds: u8 = 0,
    /// Whether a publish walk is in flight for this entry right now.
    sending: bool = false,
    /// When the last walk started, so the next one waits.
    last_try_at: i64 = 0,

    /// How many relays have taken it.
    pub fn ackCount(self: OutboxEntry) usize {
        return @popCount(self.acked);
    }

    /// Where this note is, in the words the popover uses.
    pub fn state(self: OutboxEntry) OutboxState {
        if (self.acked != 0) return .sent;
        if (self.sending) return .sending;
        if (self.rounds >= max_outbox_rounds) return .stuck;
        return .queued;
    }
};

pub const OutboxState = enum { queued, sending, sent, stuck };

/// How long to wait before offering a note again, widening with each attempt so
/// a relay that is down is asked minutes apart rather than every second.
fn outboxRetryDelay(rounds: u8) i64 {
    return switch (rounds) {
        0 => 0,
        1 => 5,
        2 => 20,
        3 => 60,
        else => 300,
    };
}

/// Set when a note could not be queued at all, so the reader is told rather than
/// left with a promise the app did not keep.
var g_outbox_overflow = std.atomic.Value(bool).init(false);

/// Room for a burst of posting without becoming a store of its own. A reader who
/// writes more than this while offline is past what a status bar can explain.
const outbox_cap = 16;
/// How many times a note is offered to the relays before the queue stops asking.
/// Every round is a full walk of the pool, so this is not a byte-level retry.
const max_outbox_rounds = 6;

var g_outbox = [_]OutboxEntry{.{}} ** outbox_cap;
/// Bumped whenever the queue changes, so the UI thread can tell that the
/// publisher touched something without locking.
var g_outbox_rev = std.atomic.Value(u32).init(0);
/// The same tiny spinlock the pending-signature table uses, and for the same
/// reason: every critical section here is a handful of field writes or a
/// 16-slot scan and never touches IO, while `std.Io.Mutex` would drag a
/// per-thread `io` across threads that deliberately never share one.
var g_outbox_lock = std.atomic.Value(bool).init(false);

fn outboxLock() void {
    while (g_outbox_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn outboxUnlock() void {
    g_outbox_lock.store(false, .release);
}

/// Puts `id` in the queue, or returns the entry already there. The caller holds
/// the lock.
fn outboxEntryFor(id: [32]u8) ?*OutboxEntry {
    for (&g_outbox) |*e| {
        if (e.used and std.mem.eql(u8, &e.id, &id)) return e;
    }
    return null;
}

/// Queues a note we have just signed and stored. Returns false when the queue is
/// full of notes that have not been acknowledged, which is a state the reader can
/// see rather than one the app hides.
fn enqueueOutbox(id: [32]u8, now_s: i64) bool {
    outboxLock();
    defer outboxUnlock();
    if (outboxEntryFor(id) != null) return true;
    for (&g_outbox) |*e| {
        if (!e.used) {
            e.* = .{ .used = true, .id = id, .queued_at = now_s };
            _ = g_outbox_rev.fetchAdd(1, .monotonic);
            return true;
        }
    }
    // Full: drop the oldest note that has already reached somebody, since its
    // record is the least useful thing here.
    var victim: ?*OutboxEntry = null;
    for (&g_outbox) |*e| {
        if (e.acked == 0) continue;
        if (victim == null or e.queued_at < victim.?.queued_at) victim = e;
    }
    const slot = victim orelse return false;
    slot.* = .{ .used = true, .id = id, .queued_at = now_s };
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
    return true;
}

/// Records what one relay said about one note.
fn recordOutboxAck(id: [32]u8, relay_index: usize, accepted: bool) void {
    if (relay_index >= relays.len) return;
    outboxLock();
    defer outboxUnlock();
    const e = outboxEntryFor(id) orelse return;
    const bit = @as(u8, 1) << @intCast(relay_index);
    if (accepted) e.acked |= bit else e.refused |= bit;
    _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// A snapshot of the queue for the view, newest first. The view never reads the
/// queue directly: the publisher writes it from its own thread.
pub fn outboxSnapshot(out: []OutboxEntry) usize {
    outboxLock();
    defer outboxUnlock();
    var n: usize = 0;
    for (&g_outbox) |*e| {
        if (!e.used or n == out.len) continue;
        out[n] = e.*;
        n += 1;
    }
    std.mem.sort(OutboxEntry, out[0..n], {}, struct {
        fn lt(_: void, a: OutboxEntry, b: OutboxEntry) bool {
            return a.queued_at > b.queued_at;
        }
    }.lt);
    return n;
}

/// How many notes are still trying, and how many have given up. They are
/// counted apart because they say different things: one is work in progress,
/// the other is a note the reader wrote that never left.
pub const OutboxCounts = struct { trying: usize = 0, stuck: usize = 0 };

pub fn outboxCounts() OutboxCounts {
    outboxLock();
    defer outboxUnlock();
    var counts: OutboxCounts = .{};
    for (&g_outbox) |*e| {
        if (!e.used or e.acked != 0) continue;
        if (e.state() == .stuck) counts.stuck += 1 else counts.trying += 1;
    }
    return counts;
}

/// How many notes are still waiting for their first relay, trying or not.
pub fn outboxPending() usize {
    const c = outboxCounts();
    return c.trying + c.stuck;
}

/// Forgets the notes that are done: acknowledged by somebody, or refused by
/// everyone that answered after enough rounds. Called once the reader has had a
/// chance to see them, so the zone does not blink out mid-glance.
fn sweepOutbox(now_s: i64) void {
    outboxLock();
    defer outboxUnlock();
    var changed = false;
    for (&g_outbox) |*e| {
        if (!e.used or e.sending) continue;
        // A note that LANDED is let go once it has been on screen long enough to
        // read. A note that did not is KEPT: erasing it would be the app quietly
        // dropping something the reader wrote, which is the one thing this queue
        // exists to prevent. It stops asking, and it stays visible as stuck.
        if (e.acked != 0 and now_s - e.queued_at > outbox_sent_linger_s) {
            e.* = .{};
            changed = true;
        }
    }
    if (changed) _ = g_outbox_rev.fetchAdd(1, .monotonic);
}

/// How long a sent note stays in the queue so the reader can see that it landed.
const outbox_sent_linger_s: i64 = 20;
/// The revision last written to disk, so the queue is saved when it changes and
/// not on every tick.
var g_outbox_saved_rev: u32 = 0;

/// The queue's own seams, so a test drives the real state machine rather than a
/// copy of it.
pub fn resetOutboxForTest() void {
    outboxLock();
    defer outboxUnlock();
    for (&g_outbox) |*e| e.* = .{};
}

pub fn enqueueOutboxForTest(id: [32]u8, now_s: i64) bool {
    return enqueueOutbox(id, now_s);
}

pub fn recordOutboxAckForTest(id: [32]u8, relay_index: usize, accepted: bool) void {
    recordOutboxAck(id, relay_index, accepted);
}

pub fn countOutboxRoundForTest(id: [32]u8) void {
    markOutboxSending(id, true);
    markOutboxSending(id, false);
}

pub fn sweepOutboxForTest(now_s: i64) void {
    sweepOutbox(now_s);
}

pub fn outboxRetryDelayForTest(rounds: u8) i64 {
    return outboxRetryDelay(rounds);
}

pub const max_outbox_rounds_for_test = max_outbox_rounds;
pub const outbox_sent_linger_for_test = outbox_sent_linger_s;

/// The queue's key in the store's generic table. The events themselves are in
/// the store's own event tables (we ingest what we sign), so this holds only the
/// index: which ids are owed, and what each relay said.
const outbox_key = "outbox";

/// Writes the queue where a restart can find it. A note written on a train and
/// lost on landing is the worst thing a client can do, so this runs on every
/// change rather than at exit, which may never come.
fn saveOutbox() void {
    const store = g_store orelse return;
    // Snapshotted under the lock, written outside it. `store.put` opens a write
    // transaction and commits it, which fsyncs and waits on LMDB's writer mutex
    // that the ingest threads hold: holding a SPINLOCK across that would burn a
    // core in every publisher and stall the frame that reads the queue. The lock
    // is only justified while it is what it claims to be, a few field writes.
    var entries: [outbox_cap]OutboxEntry = undefined;
    var n: usize = 0;
    outboxLock();
    for (&g_outbox) |*e| {
        if (!e.used) continue;
        entries[n] = e.*;
        n += 1;
    }
    outboxUnlock();

    // Room for every entry at its longest: 64 hex, four separators, a ten-digit
    // second, three small numbers and a newline. Sized at the worst case rather
    // than the typical one, because a short buffer would drop the LAST entries,
    // which is exactly when the queue matters most.
    var buf: [outbox_cap * 100]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for (entries[0..n]) |e| {
        var hex: [64]u8 = undefined;
        writeHexId(&hex, e.id);
        // A short write means the buffer was mis-sized, so nothing is written at
        // all: a truncated index would silently lose notes on the next start.
        w.print("{s}:{d}:{d}:{d}:{d}\n", .{ hex[0..], e.queued_at, e.acked, e.refused, e.rounds }) catch return;
    }
    store.put(outbox_key, w.buffered()) catch {};
}

fn writeHexId(out: *[64]u8, id: [32]u8) void {
    const hexdigits = "0123456789abcdef";
    for (id, 0..) |b, i| {
        out[i * 2] = hexdigits[b >> 4];
        out[i * 2 + 1] = hexdigits[b & 0x0f];
    }
}

/// Reads the queue back at boot. Anything whose event is no longer in the store
/// is dropped: the index points at events, and an index without its event is not
/// something the reader can be shown or the app can publish.
fn loadOutbox() void {
    const store = g_store orelse return;
    const raw = (store.get(std.heap.page_allocator, outbox_key) catch return) orelse return;
    defer std.heap.page_allocator.free(raw);
    // Parsed and resolved first, installed second: every `getEvent` below opens a
    // read transaction, and the lock may not span IO.
    var parsed: [outbox_cap]OutboxEntry = undefined;
    var lines = std.mem.tokenizeScalar(u8, raw, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (n == parsed.len) break;
        var parts = std.mem.splitScalar(u8, line, ':');
        const hex = parts.next() orelse continue;
        if (hex.len != 64) continue;
        var id: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, hex) catch continue;
        const queued_at = std.fmt.parseInt(i64, parts.next() orelse "0", 10) catch continue;
        const acked = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
        const refused = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
        const rounds = std.fmt.parseInt(u8, parts.next() orelse "0", 10) catch 0;
        // The event has to still be there, or there is nothing to publish.
        const se = (store.getEvent(std.heap.page_allocator, id) catch continue) orelse continue;
        var owned = se;
        owned.deinit();
        parsed[n] = .{ .used = true, .id = id, .queued_at = queued_at, .acked = acked, .refused = refused, .rounds = rounds };
        n += 1;
    }
    outboxLock();
    defer outboxUnlock();
    for (parsed[0..n], g_outbox[0..n]) |src, *dst| dst.* = src;
}

/// Offers every note that nobody has taken to the relays again. Called when a
/// relay comes back, which is the moment the answer might have changed.
fn drainOutbox(gpa: std.mem.Allocator) void {
    const store = g_store orelse return;
    var ids: [outbox_cap][32]u8 = undefined;
    var n: usize = 0;
    const now = nowSeconds();
    outboxLock();
    for (&g_outbox) |*e| {
        if (!e.used or e.sending or e.acked != 0 or e.rounds >= max_outbox_rounds) continue;
        // Spaced out, and widening: the drain runs every tick, so without this a
        // transient failure (a captive portal, a TLS error, a relay that takes
        // the socket and refuses the publish) would burn every round in seconds
        // and leave the note stuck a moment after it was written.
        if (e.last_try_at != 0 and now - e.last_try_at < outboxRetryDelay(e.rounds)) continue;
        if (n == ids.len) break;
        e.last_try_at = now;
        ids[n] = e.id;
        n += 1;
    }
    outboxUnlock();
    for (ids[0..n]) |id| {
        var se = (store.getEvent(gpa, id) catch continue) orelse continue;
        defer se.deinit();
        // COPIED, not borrowed. `StoredEvent.deinit` tears down the arena that
        // backs the content and the tags, and it would fire at the end of this
        // iteration, while the detached publisher is still serialising them.
        // `ingestAndPublish` states the same rule for its own path: what the
        // publisher reads has to outlive the call that spawned it.
        const owned = dupeEventForPublish(se.event) orelse continue;
        const thread = std.Thread.spawn(.{}, publishOwnedWorker, .{ gpa, owned }) catch {
            freePublishedEvent(owned);
            continue;
        };
        thread.detach();
    }
}

/// A process-lifetime copy of an event, for handing to a detached publisher.
/// Returns null when the copy cannot be made, in which case nothing is spawned.
fn dupeEventForPublish(ev: nostr.event.Event) ?nostr.event.Event {
    const gpa = std.heap.page_allocator;
    var out = ev;
    out.content = gpa.dupe(u8, ev.content) catch return null;
    const tags = gpa.alloc(nostr.event.Tag, ev.tags.len) catch {
        gpa.free(out.content);
        return null;
    };
    var filled: usize = 0;
    errdefer {
        for (tags[0..filled]) |t| {
            for (t) |field| gpa.free(field);
            gpa.free(t);
        }
        gpa.free(tags);
        gpa.free(out.content);
    }
    for (ev.tags, tags) |src, *dst| {
        const fields = gpa.alloc([]const u8, src.len) catch return null;
        var wrote: usize = 0;
        for (src, fields) |field, *slot| {
            slot.* = gpa.dupe(u8, field) catch {
                for (fields[0..wrote]) |f| gpa.free(f);
                gpa.free(fields);
                return null;
            };
            wrote += 1;
        }
        dst.* = fields;
        filled += 1;
    }
    out.tags = tags;
    return out;
}

/// Frees what `dupeEventForPublish` allocated.
fn freePublishedEvent(ev: nostr.event.Event) void {
    const gpa = std.heap.page_allocator;
    for (ev.tags) |t| {
        for (t) |field| gpa.free(field);
        gpa.free(t);
    }
    gpa.free(ev.tags);
    gpa.free(ev.content);
}

/// The drain's worker: publishes a copy it owns, and frees it when the walk is
/// over rather than leaving it to a caller that has already moved on.
fn publishOwnedWorker(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    defer freePublishedEvent(ev);
    publishWorker(gpa, ev);
}

/// Publishes `ev` to every relay in the pool, each on a throwaway connection,
/// best-effort. Posting is a rare, human-paced action, so a fresh dial per post
/// keeps the ingest loops untouched; the note is already in the local store, so
/// the feed shows it regardless of publish latency. Runs on a detached thread
/// with its own io backend, never the UI thread's.
fn publishEvent(gpa: std.mem.Allocator, ev: nostr.event.Event) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (relays, 0..) |url, i| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();
        relay.publish(ev) catch continue;
        // The relay's OK is the answer to "is my note out there", so it is READ
        // rather than merely waited for: which relay took it, and which refused,
        // is the whole content of the outbox. A relay may say other things
        // first (a NOTICE, an EVENT for an open subscription), so this reads
        // until it sees a verdict for THIS id or runs out of patience.
        var seen: usize = 0;
        while (seen < max_publish_messages) : (seen += 1) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .ok => |ok| {
                    if (!std.mem.eql(u8, &ok.event_id, &ev.id)) continue;
                    recordOutboxAck(ev.id, i, ok.accepted);
                    break;
                },
                else => continue,
            }
        }
    }
}

/// How many frames to read from one relay while waiting for its verdict. A relay
/// with a busy subscription can have several in front of the OK; past this it is
/// not answering about this note.
const max_publish_messages = 8;

// ------------------------------------------------------------------------ threads
//
// A thread is the focused note plus the kind:1 replies that e-tag it. It is
// layered OVER the feed, which stays mounted so its scroll offset survives.
// Opening one snapshots the root, reads any replies already in the store, and
// fires a one-shot fetch of the rest (with their engagement) into the store; the
// replies are cached in the model so they are pressable (open as a sub-thread)
// and get their pictures fetched, the same local-first path the feed uses.

/// Opens `note_id` as a thread. The target may live in the feed or the current
/// thread; it is snapshotted as the new root so it survives store rebuilds. When
/// a thread is already open, the current root is pushed so Back returns to it.
fn openThread(model: *Model, note_id: i64) void {
    const target = model.noteById(note_id) orelse return;
    enterThread(model, target.*);
}

/// Focuses `root` as the open thread: pushes the current thread (if any) onto
/// the back-stack, snapshots the new root, and fires its reply fetch. Shared by
/// open-a-feed-note, open-a-reply, and open-a-quoted-note.
fn enterThread(model: *Model, root: Note) void {
    if (model.viewing_thread != 0 and model.thread_stack_len < model.thread_stack.len) {
        model.thread_stack[model.thread_stack_len] = model.thread_root;
        model.thread_stack_len += 1;
    }
    model.viewing_thread = root.id;
    model.thread_root = root;
    model.thread_notes_len = 0;
    model.reply_buffer.clear();
    // The level being opened starts at its first page with its held section
    // closed. Only this level: the ones underneath keep what the reader left
    // them holding. The arrival table needs no reset either, since it is keyed
    // by the level's root and discards itself when it finds another thread.
    model.thread_page[model.currentLevel()] = 1;
    model.thread_outside_open[model.currentLevel()] = false;
    wantProfile(root.pubkey);
    // The fetch is claimed BEFORE the first build, because that build asks
    // whether this level's fetch has settled: against the previous level's
    // sequence it would answer yes, mark the table settled before a single
    // reply had landed, and put the whole opening read back into relay-answer
    // order, which is the thing arrival batching exists to prevent.
    const now = nowSeconds();
    const seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
    model.thread_seq = seq;
    model.thread_open_at = now;
    model.refreshThreadNotes(now);
    model.thread_loading = model.thread_notes_len == 0;
    fetchThreadReplies(root.event_id, seq);
}

/// The level bookkeeping, for a test that walks a stack up and down. Both take
/// the same paths the app does, so what they assert is what a reader gets.
pub fn enterThreadForTest(model: *Model, root: Note) void {
    enterThread(model, root);
}

pub fn closeThreadForTest(model: *Model) void {
    closeThread(model);
}

/// Opens an event (by its full id) as a thread, reading it straight from the
/// store. `openThread` cannot: it resolves the render key through the feed and
/// the open thread, and a quoted note or an ANCESTOR is in neither. Both press
/// this instead, and both only ever fire for an event already ingested (an
/// unresolved quote card is not pressable, and an ancestor row exists because
/// the walk found the event).
fn openEvent(model: *Model, id: [32]u8) void {
    const store = g_store orelse return;
    var se = (store.getEvent(std.heap.page_allocator, id) catch return) orelse return;
    defer se.deinit();
    enterThread(model, noteFrom(se.event, nowSeconds()));
}

/// Closes the open thread: pops the back-stack to the thread it was opened from,
/// or returns to the feed (which kept its scroll offset) when the stack is empty.
fn closeThread(model: *Model) void {
    // The level being left is the one that resets: the level underneath keeps
    // its pages, its held section and its arrival order, which is what makes the
    // walk back land where the reader left it.
    model.thread_page[model.currentLevel()] = 1;
    model.thread_outside_open[model.currentLevel()] = false;
    model.reply_buffer.clear();
    model.thread_notes_len = 0;
    if (model.thread_stack_len > 0) {
        model.thread_stack_len -= 1;
        const prev = model.thread_stack[model.thread_stack_len];
        model.viewing_thread = prev.id;
        model.thread_root = prev;
        // Same ordering as `enterThread`, and for the same reason.
        const now = nowSeconds();
        const seq = g_thread_seq.fetchAdd(1, .monotonic) + 1;
        model.thread_seq = seq;
        model.thread_open_at = now;
        model.refreshThreadNotes(now);
        model.thread_loading = model.thread_notes_len == 0;
        fetchThreadReplies(prev.event_id, seq);
    } else {
        model.viewing_thread = 0;
        model.thread_loading = false;
    }
}

// The open-thread generation, so a reply fetch can report completion for the
// thread it was launched for and not a later one. `g_thread_seq` is bumped on
// each open; the worker copies its seq and, when it has asked every relay,
// stores it into `g_thread_done_seq`. The UI thread clears the loading skeletons
// only when the CURRENT thread's fetch is the one that finished (so a genuinely
// empty thread stops loading, but a stale late worker never clears a new thread).
var g_thread_seq = std.atomic.Value(u64).init(0);
var g_thread_done_seq = std.atomic.Value(u64).init(0);

/// Fetches a note's replies (and their engagement) into the store, on a detached
/// thread. One dial per relay: opening a thread is a rare, human-paced action, so
/// a throwaway connection keeps the ingest loops untouched, exactly like
/// publishing. `seq` tags the fetch so its completion is attributable.
fn fetchThreadReplies(root_id: [32]u8, seq: u64) void {
    // Nowhere to put the replies without a store; the guard also keeps tests,
    // which have no store, from dialing relays. Mark it done at once so the UI
    // does not wait on a fetch that never ran.
    if (g_store == null) {
        g_thread_done_seq.store(seq, .release);
        return;
    }
    const thread = std.Thread.spawn(.{}, fetchRepliesWorker, .{ root_id, seq }) catch {
        g_thread_done_seq.store(seq, .release);
        return;
    };
    thread.detach();
}

fn fetchRepliesWorker(root_id: [32]u8, seq: u64) void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    var root_hex: [64]u8 = undefined;
    hexLower(&root_hex, root_id);

    for (relays) |url| {
        var relay = nostr.relay.dial(gpa, io, url) catch continue;
        defer relay.deinit();

        // Phase 1: the replies themselves (kind:1 e-tagging the root). Collect
        // their ids as they arrive so phase 2 can watch their engagement too.
        var id_hex: [thread_reply_cap][64]u8 = undefined;
        var watch_ids: [thread_reply_cap + 1]i64 = undefined;
        var id_count: usize = 0;
        // The root is watched from the start, so its own counts refresh.
        watch_ids[0] = @intCast(std.mem.readInt(u64, root_id[0..8], .big) & std.math.maxInt(i64));
        var watch_len: usize = 1;

        const reply_kinds = [_]u16{1};
        const root_evals = [_][]const u8{&root_hex};
        const reply_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = &root_evals }};
        const reply_filters = [_]nostr.filter.Filter{.{ .kinds = &reply_kinds, .tags = &reply_tags, .limit = thread_reply_cap }};
        relay.subscribe("plaza-thread", &reply_filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    const store = g_store orelse continue;
                    _ = store.ingest(gpa, e.event, .{ .verify_with = signer }) catch {};
                    // Queue the replier's profile so a name and face resolve.
                    wantProfile(e.event.pubkey);
                    if (id_count < thread_reply_cap) {
                        hexLower(&id_hex[id_count], e.event.id);
                        id_count += 1;
                        watch_ids[watch_len] = noteIdOf(e.event);
                        watch_len += 1;
                    }
                },
                .eose => break,
                else => {},
            }
        }

        // Phase 2: engagement on the root and every reply (replies, reposts,
        // likes, zaps), folded into the shared table so the thread shows real
        // metrics on each row, the same counts the feed shows.
        var evals: [thread_reply_cap + 1][]const u8 = undefined;
        evals[0] = &root_hex;
        var eval_len: usize = 1;
        for (0..id_count) |i| {
            evals[eval_len] = &id_hex[i];
            eval_len += 1;
        }
        const eng_kinds = [_]u16{ 1, 6, 7, 9735 };
        const eng_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = evals[0..eval_len] }};
        const eng_filters = [_]nostr.filter.Filter{.{ .kinds = &eng_kinds, .tags = &eng_tags, .limit = 500 }};
        relay.subscribe("plaza-thread-eng", &eng_filters) catch continue;
        while (true) {
            var msg = (relay.receive() catch break) orelse break;
            defer msg.deinit();
            switch (msg.value) {
                .event => |e| {
                    if (nostr.event.verify(gpa, signer, e.event) catch false)
                        countEngagement(e.event, watch_ids[0..watch_len]);
                },
                .eose => break,
                else => {},
            }
        }
    }
    // Every relay has been asked: the reply set is as complete as it will get, so
    // the UI can stop showing loading skeletons even if nothing came back.
    g_thread_done_seq.store(seq, .release);
}

// ------------------------------------------------------- remote signer (NIP-46)
//
// Signing can be routed to an external signer (Signet) over NIP-46 so the user's
// secret key never enters Plaza. Plaza is the CLIENT: it holds an ephemeral
// transport keypair, and the user's identity is the bunker's own pubkey. The
// wire is kind:24133 events whose content is a NIP-44-encrypted request/response
// `p`-tagged to the recipient. A persistent listener thread holds the bunker
// relay and processes responses; each request (connect, then one per post) goes
// out on its own short-lived connection, so a blocked receive never stalls a
// send. A signed note returns as a response `result`, stored and published to
// the feed pool exactly like a locally signed one.

/// Pairs with an external signer from a `bunker://` URL: parses it, mints an
/// ephemeral client key, starts the response listener, and sends the connect
/// request. Returns false (and marks the status failed) on a bad URL.
fn connectRemoteSigner(url_raw: []const u8) bool {
    const url = std.mem.trim(u8, url_raw, " \t\r\n");
    const io = g_io orelse return false;
    const gpa = std.heap.page_allocator;

    var parsed = nostr.nip46.parseBunkerUri(gpa, url) catch {
        g_remote_status.store(3, .release);
        return false;
    };
    defer parsed.deinit();
    const bunker = parsed.value;
    if (bunker.relays.len == 0 or bunker.relays[0].len > g_remote_relay_buf.len) {
        g_remote_status.store(3, .release);
        return false;
    }
    const relay_url = bunker.relays[0];

    // Mint the ephemeral transport key (never the user's key).
    var signer = nostr.keys.Signer.init();
    const client_kp = signer.generateKeyPair(io) catch {
        signer.deinit();
        g_remote_status.store(3, .release);
        return false;
    };
    signer.deinit();

    // Stash the connection details for the worker threads.
    g_remote_pubkey = bunker.remote_signer_pubkey;
    @memcpy(g_remote_relay_buf[0..relay_url.len], relay_url);
    g_remote_relay_len = relay_url.len;
    if (bunker.secret) |s| {
        const n = @min(s.len, g_remote_secret_buf.len);
        @memcpy(g_remote_secret_buf[0..n], s[0..n]);
        g_remote_secret_len = n;
    } else g_remote_secret_len = 0;
    g_remote_client_kp = client_kp;

    // The user's identity is the bunker's pubkey.
    const npub = abbreviateNpub(&g_identity_npub_buf, g_remote_pubkey);
    g_identity_npub_len = npub.len;
    g_signer_kind = .remote;
    g_remote_status.store(1, .release);
    g_remote_sign_notice.store(false, .release);

    // A fresh generation: any prior listener (a reconnect to a second bunker)
    // stops processing, and every request registered from here carries it.
    const generation = g_remote_generation.fetchAdd(1, .monotonic) + 1;

    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{ gpa, generation }) catch {
        g_remote_status.store(3, .release);
        return false;
    };
    thread.detach();

    sendConnect(gpa);
    return true;
}

/// Sends the NIP-46 `connect` request (remote pubkey + optional secret).
fn sendConnect(gpa: std.mem.Allocator) void {
    var hexbuf: [64]u8 = undefined;
    hexLower(&hexbuf, g_remote_pubkey);
    var idbuf: [24]u8 = undefined;
    const req_id = std.fmt.bufPrint(&idbuf, "req-{d}", .{g_req_counter.fetchAdd(1, .monotonic)}) catch return;
    if (!registerPending(req_id, .connect, null, false)) return;
    const params = [_][]const u8{ &hexbuf, g_remote_secret_buf[0..g_remote_secret_len] };
    sendRequest(gpa, .{ .id = req_id, .method = "connect", .params = &params });
}

/// Remote path: build the unsigned event of `kind` (with `tags`, stamped
/// `created_at`) and send a `sign_event` request. The signed event returns to
/// the listener, which stores and publishes it. `restorable` is true only for a
/// composer draft, so a failed reaction never lands "+"-text in the composer.
fn requestRemoteSign(gpa: std.mem.Allocator, created_at: i64, kind: u16, tags: []const nostr.event.Tag, content_owned: []const u8, restorable: bool) void {
    // `content_owned` is handed to the pending slot (so a timeout can restore
    // it to the composer); it is freed here only on an early return.
    // A canonical unsigned event (the bunker fills in the signature). The id is
    // computed against the user's pubkey so the bunker's result matches it.
    const id = nostr.event.computeId(gpa, g_remote_pubkey, created_at, kind, tags, content_owned) catch {
        gpa.free(content_owned);
        return;
    };
    const unsigned = nostr.event.Event{
        .id = id,
        .pubkey = g_remote_pubkey,
        .created_at = created_at,
        .kind = kind,
        .tags = tags,
        .content = content_owned,
        .sig = [_]u8{0} ** 64,
    };
    const unsigned_json = nostr.event.toJson(gpa, unsigned) catch {
        gpa.free(content_owned);
        return;
    };
    defer gpa.free(unsigned_json);

    var idbuf: [24]u8 = undefined;
    const req_id = std.fmt.bufPrint(&idbuf, "req-{d}", .{g_req_counter.fetchAdd(1, .monotonic)}) catch {
        gpa.free(content_owned);
        return;
    };
    // Track before sending: the response can arrive on the listener thread the
    // instant the send lands, and it must find the pending slot already there.
    if (!registerPending(req_id, .sign_event, content_owned, restorable)) {
        gpa.free(content_owned);
        return;
    }
    const params = [_][]const u8{unsigned_json};
    sendRequest(gpa, .{ .id = req_id, .method = "sign_event", .params = &params });
}

/// Serializes `request` and spawns a one-shot thread to seal and publish it.
fn sendRequest(gpa: std.mem.Allocator, request: nostr.nip46.Request) void {
    const req_json = request.toJson(gpa) catch return;
    const thread = std.Thread.spawn(.{}, nip46Send, .{ gpa, req_json }) catch {
        gpa.free(req_json);
        return;
    };
    thread.detach();
}

/// Seals `req_json` to the remote signer and publishes it on a throwaway
/// connection to the bunker relay. Owns `req_json`. Its own io and signer.
fn nip46Send(gpa: std.mem.Allocator, req_json: []const u8) void {
    defer gpa.free(req_json);
    const client_kp = g_remote_client_kp orelse return;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    const created_at = std.Io.Timestamp.now(io, .real).toSeconds();
    var sealed = nostr.nip46.seal(gpa, io, signer, client_kp, g_remote_pubkey, req_json, created_at) catch return;
    defer sealed.deinit();

    var relay = nostr.relay.dial(gpa, io, g_remote_relay_buf[0..g_remote_relay_len]) catch return;
    defer relay.deinit();
    relay.publish(sealed.event) catch return;
    // Read the relay's OK so the frame flushes before we close; best-effort.
    var msg = (relay.receive() catch return) orelse return;
    msg.deinit();
}

/// The response listener: holds the bunker relay and processes responses,
/// reconnecting until its `generation` is superseded (a logout or a reconnect
/// bumps `g_remote_generation`). Its own io backend and signer, never the UI
/// thread's.
fn nip46ReceiveLoop(gpa: std.mem.Allocator, generation: u64) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const client_kp = g_remote_client_kp orelse return;

    while (generation == g_remote_generation.load(.acquire)) {
        nip46ReceiveOnce(gpa, io, signer, client_kp, generation) catch |err| {
            std.debug.print("plaza: [signer] {s}\n", .{@errorName(err)});
        };
        if (generation != g_remote_generation.load(.acquire)) break;
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Dials the bunker relay, subscribes for responses addressed to our client key
/// (`#p` = the ephemeral pubkey, which only our bunker knows), and handles each
/// until the connection drops or this listener's `generation` is superseded.
fn nip46ReceiveOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair, generation: u64) !void {
    var relay = try nostr.relay.dial(gpa, io, g_remote_relay_buf[0..g_remote_relay_len]);
    defer relay.deinit();

    var client_hex: [64]u8 = undefined;
    hexLower(&client_hex, client_kp.public_key);
    const pvals = [_][]const u8{&client_hex};
    const tag_filters = [_]nostr.filter.TagFilter{.{ .letter = 'p', .values = &pvals }};
    const kinds = [_]u16{nostr.nip46.kind};
    const filters = [_]nostr.filter.Filter{.{ .kinds = &kinds, .tags = &tag_filters }};
    try relay.subscribe("plaza-nip46", &filters);

    while (generation == g_remote_generation.load(.acquire)) {
        var msg = (try relay.receive()) orelse break;
        defer msg.deinit();
        switch (msg.value) {
            .event => |e| handleNip46Response(gpa, signer, client_kp, e.event, generation),
            else => {},
        }
    }
}

/// Decrypts, parses, and correlates a NIP-46 response to the request that asked
/// for it. An error response flags its request so the UI restores the draft; a
/// `sign_event` result is verified, stored, and published to the feed pool (the
/// remote equivalent of the local post path); a `connect` ack marks connected.
/// An unknown or already-handled id is dropped, so a duplicate never publishes
/// twice and a stale session's response never lands.
fn handleNip46Response(gpa: std.mem.Allocator, signer: nostr.keys.Signer, client_kp: nostr.keys.KeyPair, ev: nostr.event.Event, generation: u64) void {
    if (generation != g_remote_generation.load(.acquire)) return;
    const plaintext = nostr.nip46.open(gpa, signer, client_kp.secret_key, ev) catch return;
    defer gpa.free(plaintext);
    var resp = nostr.nip46.parseResponse(gpa, plaintext) catch return;
    defer resp.deinit();

    if (resp.value.err.len != 0) {
        std.debug.print("plaza: [signer] {s}\n", .{resp.value.err});
        // Leave the slot in the table, flagged: the UI tick owns the composer,
        // so it restores the draft (sign) or fails the status (connect).
        _ = failPending(resp.value.id);
        return;
    }

    // Correlate to the request that asked. A missing slot means an unknown id
    // or one already handled: drop it (no double publish, no stray "connected").
    const pending = takePending(resp.value.id) orelse return;
    defer if (pending.content) |c| gpa.free(c);

    g_remote_status.store(2, .release);
    g_remote_sign_notice.store(false, .release);

    switch (pending.method) {
        // The connect ack is a plain "ack" string; the status above is the point.
        .connect => {},
        .sign_event => {
            var parsed = nostr.event.fromJson(gpa, resp.value.result) catch return;
            defer parsed.deinit();
            // A process-lifetime copy of the content: `parsed` is freed on
            // return, but the detached publisher reads it afterwards. Our
            // composer produces tagless kind:1 notes, so an empty tag set still
            // matches the signed id, and the write seam verifies that before
            // trusting it into the feed.
            const owned = gpa.dupe(u8, parsed.value.content) catch return;
            var out = parsed.value;
            out.content = owned;
            // Preserve the signed tags (a reaction carries e/p/k); forcing them
            // empty would make the id not match, and the verify below would drop
            // it. Deep-copied because `parsed` is freed on return.
            out.tags = dupeTags(gpa, parsed.value.tags);
            ingestAndPublish(gpa, out, signer);
        },
    }
}

/// UI-thread sweep of the pending table (called each tick): a request that
/// failed or ran past its deadline is retired here, where the composer can be
/// touched. A timed-out or refused `sign_event` restores its draft (only into
/// an empty composer, so a newer draft is never clobbered) and shows a notice;
/// a `connect` that never returned fails the connection status. A slot from a
/// superseded generation (logout/reconnect) is dropped silently.
fn scanPendingRemote(model: *Model) void {
    const now = nowSeconds();
    const gpa = std.heap.page_allocator;
    const generation = g_remote_generation.load(.acquire);
    var restore: ?[]const u8 = null;
    var sign_failed = false;
    var connect_failed = false;

    pendingLock();
    for (&g_pending) |*slot| {
        if (!slot.active) continue;
        const stale = slot.generation != generation;
        const due = slot.failed or now >= slot.deadline_s;
        if (!stale and !due) continue;
        const method = slot.method;
        const content = slot.content;
        const slot_restorable = slot.restorable;
        slot.* = .{};
        if (stale) {
            if (content) |c| gpa.free(c);
            continue;
        }
        switch (method) {
            .sign_event => {
                // The composer holds one draft: keep the first restorable one,
                // free the rest. A reaction's content is not restorable, so it
                // is freed and its failure stays silent.
                if (content) |c| {
                    if (slot_restorable and restore == null) restore = c else gpa.free(c);
                }
                if (slot_restorable) sign_failed = true;
            },
            .connect => {
                if (content) |c| gpa.free(c);
                connect_failed = true;
            },
        }
    }
    pendingUnlock();

    if (restore) |c| {
        if (model.draft_empty()) model.draft_buffer.set(c);
        gpa.free(c);
    }
    if (sign_failed) g_remote_sign_notice.store(true, .release);
    if (connect_failed and g_remote_status.load(.acquire) == 1) g_remote_status.store(3, .release);
}

/// Lowercase-hex-encodes a 32-byte key into `out`.
fn hexLower(out: *[64]u8, bytes: [32]u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
}

// -------------------------------------------------------------------- app run

// CoreText/CoreGraphics, for registering the bundled faces process-wide by
// PostScript name. Already linked: the SDK's AppKit host uses CTFontManager.
const ct = if (builtin.os.tag == .macos) struct {
    const CGDataProviderRef = ?*anyopaque;
    const CGFontRef = ?*anyopaque;
    const CFTypeRef = ?*anyopaque;
    extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: [*]const u8, size: usize, release: ?*anyopaque) CGDataProviderRef;
    extern "c" fn CGDataProviderRelease(provider: CGDataProviderRef) void;
    extern "c" fn CGFontCreateWithDataProvider(provider: CGDataProviderRef) CGFontRef;
    extern "c" fn CGFontRelease(font: CGFontRef) void;
    extern "c" fn CTFontManagerRegisterGraphicsFont(font: CGFontRef, err: ?*CFTypeRef) bool;
    extern "c" fn CFRelease(ref: CFTypeRef) void;
} else struct {};

/// Installs Plaza's own vector icons (plaza_icons.zig) so `ui.appIcon` names
/// resolve like built-ins. Idempotent: it just publishes a static table. The
/// tests call it too, so a view built in a test draws the real glyphs instead of
/// the missing-icon fallback (and an icon regression can actually fail a test).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&plaza_icons.app_icons);
}

/// Registers the bundled Geist faces (theme.zig) with CoreText from the
/// binary's own bytes, process scope, so the host's by-name resolution of the
/// default sans/mono ids (and the reserved medium/bold span ids) finds them
/// on EVERY launch path: the live window, a dev run from any working
/// directory, and headless session replay. Best-effort per face: a face that
/// is already registered (a system-installed Geist, a second call) fails
/// quietly, and by-name lookup still resolves; either copy is the same OFL
/// family.
fn registerFontFaces() void {
    if (comptime builtin.os.tag != .macos) return;
    const faces = [_][]const u8{ theme.geist_ttf, theme.geist_medium_ttf, theme.geist_bold_ttf, theme.geist_mono_ttf };
    for (faces) |ttf| {
        const provider = ct.CGDataProviderCreateWithData(null, ttf.ptr, ttf.len, null) orelse continue;
        defer ct.CGDataProviderRelease(provider);
        const font = ct.CGFontCreateWithDataProvider(provider) orelse continue;
        defer ct.CGFontRelease(font);
        var err: ct.CFTypeRef = null;
        _ = ct.CTFontManagerRegisterGraphicsFont(font, &err);
        if (err) |e| ct.CFRelease(e);
    }
}

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    g_environ = init.environ_map;

    // The bundled Geist faces, registered with CoreText before the platform
    // host exists, so every later font lookup resolves them (see theme.zig).
    registerFontFaces();

    // The glyphs the built-in set does not carry. Registered before the first
    // view build.
    registerIcons();

    // A returning user has a persisted session: restore it (load the local key,
    // or silently reconnect the bunker) so they are signed straight back in.
    // Best-effort: on failure the app still runs, as a guest.
    loadSettings(init.io, init.environ_map);
    _ = restoreSession(init.io, init.environ_map);
    // Resolve the keyholder daemon (its path and a fresh bearer token); boot
    // spawns it. Best-effort, and non-fatal: signing still works in-process.
    resolveHelper(init);
    resolveSignetWindow(init);

    const app_state = try PlazaApp.create(std.heap.page_allocator, .{
        .name = "plaza",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = boot,
        .update_fx = update,
        .view = appView,
        .on_command = onCommand,
        // No canvas-registered fonts: the typography tokens sit on the
        // BUILT-IN ids (the SDK's default sans IS Geist), which is the only
        // routing that gives span weights real medium/bold faces; a
        // custom-registered id pins every span to its one face. The faces are
        // registered with CoreText in `registerFontFaces` instead (theme.zig).
        // The dark, cool-grey, white-accent look (see theme.zig).
        .tokens_fn = theme.tokens(Model),
    });
    defer app_state.destroy();
    app_state.model = initialModel();
    // Guest-first: the app opens INTO the feed, never a welcome wall. A
    // restored session is signed straight back in; a newcomer browses as a
    // guest (the feed reads fine without an identity) and is asked for one at
    // first intent, not at launch. Either way the store and the pool start
    // before the window appears, so the first frame renders from disk.
    app_state.model.stage = .ready;
    startFeed(init.io, init.environ_map);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "plaza",
        .window_title = "Plaza",
        .bundle_id = "com.zig-nostr.plaza",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

/// Opens the local-first store and spawns the background ingest thread. The
/// store is heap-allocated and the thread detached, both living for the whole
/// process: LMDB commits each event durably, and the ingest thread can be
/// blocked in a relay read at quit, so we deliberately never tear them down,
/// process exit reclaims them without racing the detached thread. A failure
/// here is non-fatal: the app runs with an empty feed that reads "offline".
fn startFeed(io: std.Io, environ: *const std.process.Environ.Map) void {
    if (g_store != null) return; // already running
    const gpa = std.heap.page_allocator;
    const store = gpa.create(nostr.store.Store) catch return;
    store.* = openFeedStore(io, environ) catch |err| {
        std.debug.print("plaza: local store unavailable: {s}\n", .{@errorName(err)});
        gpa.destroy(store);
        return;
    };
    g_store = store;

    // One ingest thread per relay in the pool. Each dials independently, so a
    // slow or down relay never holds up the others, and all write into the one
    // shared store (LMDB serialises the concurrent writers).
    for (0..relays.len) |i| {
        const thread = std.Thread.spawn(.{}, ingestRelay, .{ gpa, i }) catch |err| {
            std.debug.print("plaza: [{s}] could not start: {s}\n", .{ relays[i], @errorName(err) });
            setRelayStatus(i, .offline);
            continue;
        };
        thread.detach();
    }
}

/// Opens (creating if needed) the feed store at `$HOME/.plaza/feed.mdb`.
fn openFeedStore(io: std.Io, environ: *const std.process.Environ.Map) !nostr.store.Store {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    dir.close(io);

    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/feed.mdb", .{dir_path});
    return nostr.store.Store.open(db_path, .{});
}

// ----------------------------------------------------------------- identity
//
// Plaza's local signing identity lives beside the feed store, at
// `$HOME/.plaza/identity.key` (the raw 32-byte secret, mode 0600). It is created
// on the user's onboarding action, not silently: a first run with no key file
// opens the welcome screen, and "Create your identity" generates and persists
// it. This is the zero-config local signer; connecting an external signer
// (Signet, over NIP-46) so the key never touches the client is the next
// onboarding option, and swaps in at `signAndPublish`.

/// Opens (creating if needed) `$HOME/.plaza`, returning the directory handle.
fn plazaDir(io: std.Io, environ: *const std.process.Environ.Map) !std.Io.Dir {
    const home = environ.get("HOME") orelse ".";
    var dir_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.plaza", .{home});
    // mkdir -p (idempotent); an absolute sub-path ignores the cwd handle.
    return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
}

/// Loads the identity from `identity.key` if present, adopting it and returning
/// true. Never generates a key, that is the onboarding action's job.
fn loadIdentityIfPresent(io: std.Io, environ: *const std.process.Environ.Map) bool {
    var dir = plazaDir(io, environ) catch return false;
    defer dir.close(io);

    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, "identity.key", gpa, std.Io.Limit.limited(64)) catch return false;
    defer gpa.free(raw);
    if (raw.len != 32) return false;

    var signer = nostr.keys.Signer.init();
    var secret: [32]u8 = undefined;
    @memcpy(&secret, raw[0..32]);
    const kp = signer.keyPairFromSecretKey(secret) catch {
        signer.deinit();
        return false;
    };
    g_signer_kind = .local;
    setIdentity(signer, kp);
    // Queue a silent, background upgrade: move this in-process key into the
    // isolated daemon. The tick fires it once the daemon is reachable; on
    // success the identity becomes helper-held and identity.key is deleted. If
    // it never lands, the key keeps working in-process, no loss.
    g_helper_setup_secret = secret;
    g_helper_setup = .migrate;
    return true;
}

/// Generates a fresh identity, persists it (mode 0600), and adopts it. Backs the
/// onboarding "create identity" action, using the io and environment stashed in
/// `main`. Returns true on success.
fn createLocalIdentity() bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;

    var signer = nostr.keys.Signer.init();
    const kp = signer.generateKeyPair(io) catch {
        signer.deinit();
        return false;
    };

    persistIdentityKey(io, environ, kp.secret_key);
    g_signer_kind = .local;
    setIdentity(signer, kp);
    return true;
}

/// Imports an existing key from a bech32 `nsec`, persists it (mode 0600), and
/// adopts it as the local identity. Backs the onboarding "paste your nsec" path.
/// On a malformed key sets the login error and returns false.
fn importNsec(nsec: []const u8) bool {
    const io = g_io orelse return false;
    const environ = g_environ orelse return false;
    const gpa = std.heap.page_allocator;

    const secret = nostr.nip19.decodeNsec(gpa, nsec) catch {
        g_login_error.store(@intFromEnum(LoginError.bad_key), .release);
        return false;
    };
    var signer = nostr.keys.Signer.init();
    const kp = signer.keyPairFromSecretKey(secret) catch {
        signer.deinit();
        g_login_error.store(@intFromEnum(LoginError.bad_key), .release);
        return false;
    };

    persistIdentityKey(io, environ, secret);
    g_signer_kind = .local;
    setIdentity(signer, kp);
    return true;
}

/// Writes the raw 32-byte secret to `$HOME/.plaza/identity.key` at mode 0600,
/// replacing any existing file. A failure to persist is non-fatal: the session
/// still runs with the in-memory key (it just will not survive a relaunch).
fn persistIdentityKey(io: std.Io, environ: *const std.process.Environ.Map, secret: [32]u8) void {
    var dir = plazaDir(io, environ) catch |err| {
        std.debug.print("plaza: could not open key dir: {s}\n", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    // Replace any prior key (a logout deletes it, so normally there is none).
    dir.deleteFile(io, "identity.key") catch {};
    dir.writeFile(io, .{
        .sub_path = "identity.key",
        .data = &secret,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch |err| std.debug.print("plaza: could not persist identity: {s}\n", .{@errorName(err)});
}

/// Sets the identity globals: the signer, the keypair, and the abbreviated npub
/// the composer shows. The signer's secp256k1 context is used only on the UI
/// thread.
fn setIdentity(signer: nostr.keys.Signer, kp: nostr.keys.KeyPair) void {
    g_identity_signer = signer;
    g_identity_kp = kp;
    const npub = abbreviateNpub(&g_identity_npub_buf, kp.public_key);
    g_identity_npub_len = npub.len;
}

// ------------------------------------------------------------------- session
//
// The active identity is persisted as a small session file at
// `$HOME/.plaza/session` (mode 0600), a line-based `key=value` record, so a
// returning user is signed straight back in without re-entering anything. A
// local session points at `identity.key` (the raw secret already on disk); a
// remote session carries everything needed to silently reconnect the NIP-46
// bunker (the signer's pubkey, its relay, our ephemeral transport secret, and
// the connect secret), never the user's own key, which lives only in the signer.

/// Writes the session file for the current identity kind. Best-effort: a failure
/// to persist just means this identity will not auto-restore next launch.
fn persistSession() void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);

    var buf: [1024]u8 = undefined;
    const data = switch (g_signer_kind) {
        .local => std.fmt.bufPrint(&buf, "kind=local\n", .{}) catch return,
        .helper => blk: {
            if (!g_helper_has_identity) return;
            var pk_hex: [64]u8 = undefined;
            hexLower(&pk_hex, g_helper_identity_pk);
            break :blk std.fmt.bufPrint(&buf, "kind=helper\npubkey={s}\n", .{&pk_hex}) catch return;
        },
        .remote => blk: {
            const kp = g_remote_client_kp orelse return;
            var pk_hex: [64]u8 = undefined;
            hexLower(&pk_hex, g_remote_pubkey);
            var cs_hex: [64]u8 = undefined;
            hexLower(&cs_hex, kp.secret_key);
            break :blk std.fmt.bufPrint(&buf, "kind=remote\nremote_pubkey={s}\nrelay={s}\nclient_secret={s}\nsecret={s}\n", .{
                &pk_hex,
                g_remote_relay_buf[0..g_remote_relay_len],
                &cs_hex,
                g_remote_secret_buf[0..g_remote_secret_len],
            }) catch return;
        },
    };
    dir.writeFile(io, .{
        .sub_path = "session",
        .data = data,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch |err| std.debug.print("plaza: could not persist session: {s}\n", .{@errorName(err)});
}

/// Restores the persisted identity at boot. Returns whether a session was
/// restored (so the feed should start). Reads `$HOME/.plaza/session`; falls back
/// to migrating a legacy `identity.key` (pre-session installs) into a local
/// session. Any missing or malformed data returns false, landing on onboarding.
fn restoreSession(io: std.Io, environ: *const std.process.Environ.Map) bool {
    var dir = plazaDir(io, environ) catch return false;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;

    const raw = dir.readFileAlloc(io, "session", gpa, std.Io.Limit.limited(2048)) catch {
        // No session file: adopt a legacy local key if one is on disk.
        if (loadIdentityIfPresent(io, environ)) {
            persistSession();
            return true;
        }
        return false;
    };
    defer gpa.free(raw);

    var kind: []const u8 = "";
    var f_pubkey: []const u8 = "";
    var f_relay: []const u8 = "";
    var f_client_secret: []const u8 = "";
    var f_secret: []const u8 = "";
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "kind")) kind = val;
        if (std.mem.eql(u8, key, "remote_pubkey")) f_pubkey = val;
        if (std.mem.eql(u8, key, "pubkey")) f_pubkey = val;
        if (std.mem.eql(u8, key, "relay")) f_relay = val;
        if (std.mem.eql(u8, key, "client_secret")) f_client_secret = val;
        if (std.mem.eql(u8, key, "secret")) f_secret = val;
    }

    if (std.mem.eql(u8, kind, "helper")) return restoreHelperIdentity(f_pubkey);
    if (std.mem.eql(u8, kind, "local")) return loadIdentityIfPresent(io, environ);
    if (std.mem.eql(u8, kind, "remote")) return restoreRemoteSigner(gpa, f_pubkey, f_relay, f_client_secret, f_secret);
    return false;
}

/// Rebuilds the remote-signer connection from a persisted session and reconnects
/// silently: adopts the bunker pubkey as the identity, reconstructs the ephemeral
/// transport key, starts the response listener, and re-sends `connect`.
fn restoreRemoteSigner(gpa: std.mem.Allocator, pubkey_hex: []const u8, relay: []const u8, client_secret_hex: []const u8, secret: []const u8) bool {
    if (pubkey_hex.len != 64 or client_secret_hex.len != 64) return false;
    if (relay.len == 0 or relay.len > g_remote_relay_buf.len) return false;
    if (secret.len > g_remote_secret_buf.len) return false;

    var pubkey: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pubkey, pubkey_hex) catch return false;
    var client_secret: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&client_secret, client_secret_hex) catch return false;

    var signer = nostr.keys.Signer.init();
    const client_kp = signer.keyPairFromSecretKey(client_secret) catch {
        signer.deinit();
        return false;
    };
    signer.deinit();

    g_remote_pubkey = pubkey;
    @memcpy(g_remote_relay_buf[0..relay.len], relay);
    g_remote_relay_len = relay.len;
    @memcpy(g_remote_secret_buf[0..secret.len], secret);
    g_remote_secret_len = secret.len;
    g_remote_client_kp = client_kp;

    const npub = abbreviateNpub(&g_identity_npub_buf, pubkey);
    g_identity_npub_len = npub.len;
    g_signer_kind = .remote;
    g_remote_status.store(1, .release);
    g_remote_sign_notice.store(false, .release);

    // A fresh generation for this reconnected session (see `connectRemoteSigner`).
    const generation = g_remote_generation.fetchAdd(1, .monotonic) + 1;
    const thread = std.Thread.spawn(.{}, nip46ReceiveLoop, .{ gpa, generation }) catch return false;
    thread.detach();
    sendConnect(gpa);
    return true;
}

/// Loads app-wide settings (the media proxy) from `$HOME/.plaza/settings`,
/// starting from the default so a fresh install proxies out of the box.
fn loadSettings(io: std.Io, environ: *const std.process.Environ.Map) void {
    setMediaProxy(default_media_proxy);
    g_media_previews = true;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    const gpa = std.heap.page_allocator;
    const raw = dir.readFileAlloc(io, "settings", gpa, std.Io.Limit.limited(1024)) catch return;
    defer gpa.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        // An empty value is meaningful: the user chose to load originals.
        if (std.mem.eql(u8, line[0..eq], "media_proxy")) setMediaProxy(line[eq + 1 ..]);
        if (std.mem.eql(u8, line[0..eq], "media_previews")) g_media_previews = std.mem.eql(u8, line[eq + 1 ..], "on");
    }
}

/// Persists app-wide settings. Best-effort, like the session file.
fn saveSettings() void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    var buf: [512]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "media_proxy={s}\nmedia_previews={s}\n", .{
        mediaProxy(),
        if (g_media_previews) "on" else "off",
    }) catch return;
    dir.writeFile(io, .{
        .sub_path = "settings",
        .data = data,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch |err| std.debug.print("plaza: could not persist settings: {s}\n", .{@errorName(err)});
}

/// Where an unsent draft waits between launches. One slot, because the composer
/// is one sheet: a list of drafts is a different feature and the plan says so.
const draft_file = "draft";

/// Keeps what was written but not sent. The composer already survives being
/// closed within a session; this is what makes it survive the app quitting,
/// which is the case that actually loses words: a machine that sleeps, an
/// update, a crash.
///
/// Written with the same restrictive permissions as the rest of ~/.plaza,
/// because an unsent note is as private as a sent one and rather more likely
/// to be unfinished thinking.
fn saveDraft(text: []const u8) void {
    const io = g_io orelse return;
    const environ = g_environ orelse return;
    var dir = plazaDir(io, environ) catch return;
    defer dir.close(io);
    if (text.len == 0) {
        // Nothing to keep: the slot is removed rather than left holding a stale
        // draft that would reappear over the next empty composer.
        dir.deleteFile(io, draft_file) catch {};
        return;
    }
    dir.writeFile(io, .{
        .sub_path = draft_file,
        .data = text,
        .flags = .{ .permissions = secret_file_permissions },
    }) catch {};
}

/// Reads the stashed draft back, or an empty slice when there is none.
fn loadDraft(out: []u8) []const u8 {
    const io = g_io orelse return "";
    const environ = g_environ orelse return "";
    var dir = plazaDir(io, environ) catch return "";
    defer dir.close(io);
    const n = dir.readFile(io, draft_file, out) catch return "";
    return out[0..n.len];
}

/// Logs out: deletes the session (and, for a local key, the key file itself),
/// resets the identity globals, and returns to onboarding. The feed store and
/// its ingest threads keep running (they serve the starter pack regardless of
/// who is signed in); a subsequent sign-in reuses them. The user is never locked
/// in, a local key can always be copied from Settings first, and a remote
/// signer keeps the user's key throughout.
fn performLogout(model: *Model, fx: *Effects) void {
    // Forget the key in the daemon's MEMORY, not just on disk: without this the
    // health-check reads /pubkey, still sees the key, and re-adopts within a
    // tick. The latch holds until the async reset lands.
    if (g_signer_kind == .helper) helperReset(fx);
    g_logged_out = true;
    if (g_io) |io| if (g_environ) |environ| {
        if (plazaDir(io, environ)) |dir_const| {
            var dir = dir_const;
            defer dir.close(io);
            dir.deleteFile(io, "session") catch {};
            if (g_signer_kind == .local) dir.deleteFile(io, "identity.key") catch {};
            // The helper's key lives in the daemon's file; remove it too, so a
            // logout leaves no key on disk. (The running daemon keeps its copy
            // in memory until it exits with Plaza; recreating an identity in the
            // same session needs a restart.)
            if (g_signer_kind == .helper) dir.deleteFile(io, "signer.key") catch {};
        } else |_| {}
    };

    // Tear down the NIP-46 session: bumping the generation stops the detached
    // listener from processing into the next session, and the pending table is
    // emptied so no in-flight request survives the logout.
    _ = g_remote_generation.fetchAdd(1, .monotonic);
    clearPending();
    g_remote_sign_notice.store(false, .release);

    if (g_identity_signer) |*s| s.deinit();
    g_identity_signer = null;
    g_identity_kp = null;
    g_identity_npub_len = 0;
    g_helper_has_identity = false;
    g_signer_kind = .local;
    g_remote_client_kp = null;
    g_remote_relay_len = 0;
    g_remote_secret_len = 0;
    g_remote_status.store(0, .release);
    g_login_error.store(@intFromEnum(LoginError.none), .release);
    g_last_count = std.math.maxInt(usize);

    model.login_buffer.clear();
    model.draft_buffer.clear();
    model.logout_pending = false;
    model.reveal_nsec = false;
    model.notes_len = 0;
    // Never a locked door: signing out lands on the guest feed, reading
    // uninterrupted (the pool and store keep running), not a welcome wall.
    model.stage = .ready;
}

// ----------------------------------------------------------- background ingest
//
// Each relay's ingest loop runs on its own thread with its own `std.Io.Threaded`
// and its own secp256k1 context, the io backend and the signer are not shared
// across threads, the exact shape the Signet daemon uses per relay. It dials,
// subscribes for recent kind:1, verifies each event, and writes it into the
// shared store; the UI thread reads it back through `Model.refresh`.

/// One relay's ingest loop: dial, serve, and reconnect after a short delay,
/// forever.
fn ingestRelay(gpa: std.mem.Allocator, index: usize) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var signer = nostr.keys.Signer.init();
    defer signer.deinit();

    while (true) {
        // A paused pool never dials. The reader still has the whole store, so
        // pausing costs them nothing but the live tail.
        if (relaysPaused()) {
            setRelayStatus(index, .offline);
            io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            continue;
        }
        setRelayStatus(index, .connecting);
        ingestOnce(gpa, io, signer, index) catch |err| {
            std.debug.print("plaza: [{s}] {s}\n", .{ relays[index], @errorName(err) });
        };
        setRelayStatus(index, .offline);
        clearRelayRtt(index);
        io.sleep(std.Io.Duration.fromSeconds(3), .awake) catch {};
    }
}

/// Dials relay `index`, subscribes for recent kind:1, and ingests each event
/// into the shared store until the connection closes.
fn ingestOnce(gpa: std.mem.Allocator, io: std.Io, signer: nostr.keys.Signer, index: usize) !void {
    var relay = try nostr.relay.dial(gpa, io, relays[index]);
    defer relay.deinit();
    setRelayStatus(index, .connected);

    // Follow-scoped: the starter pack's recent notes for the feed, plus their
    // kind:0 metadata (and the user's own) so the feed can show real names and
    // avatars. Two filters share one subscription.
    var authors: [starter_pack.len + 1][32]u8 = starter_pack ++ [_][32]u8{undefined};
    var authors_len: usize = starter_pack.len;
    if (activePubkey()) |pk| {
        authors[authors_len] = pk;
        authors_len += 1;
    }
    const feed_kinds = [_]u16{1};
    const profile_kinds = [_]u16{0};
    const filters = [_]nostr.filter.Filter{
        .{ .authors = &starter_pack, .kinds = &feed_kinds, .limit = feed_capacity },
        .{ .authors = authors[0..authors_len], .kinds = &profile_kinds, .limit = profile_cap },
    };
    try relay.subscribe("plaza-feed", &filters);

    // Latency is measured with a PROBE, never with the subscriptions above: the
    // feed REQ asks for a 300-note backlog plus profiles, so timing it measures
    // how much this relay had to send, not how fast it answers. The probe is a
    // one-event query whose REQ-to-EOSE is the round trip the reader cares about,
    // re-sent periodically so the number stays live. The AWAKE clock, so a system
    // clock step cannot swing a reading.
    var probe_at: i64 = 0;
    var probed_at: i64 = 0;

    // The loaded notes' ids (and their hex), collected from the feed as it
    // arrives. On the feed's EOSE a second subscription opens for their
    // engagement, so counts fold in alongside the feed on the same connection.
    var feed_ids: [engagement_watch_cap]i64 = undefined;
    var feed_id_hex: [engagement_watch_cap][64]u8 = undefined;
    var feed_ids_len: usize = 0;
    var engagement_open = false;

    while (true) {
        // A pause takes effect at the next message this relay sends: the thread
        // returns, `defer relay.deinit()` closes the socket, and the reconnect
        // loop parks. A silent relay therefore holds its socket until it speaks,
        // which is why the chip says "pausing" until every thread has actually
        // left rather than claiming a pause it has not achieved.
        if (relaysPaused()) return;
        var msg = (try relay.receive()) orelse break;
        defer msg.deinit();

        // Time to re-probe? `receive()` blocks with no deadline, so the probe
        // rides the next message rather than a timer; a relay too quiet to carry
        // one is also a relay whose latency nobody is waiting on.
        const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (probe_at == 0 and (probed_at == 0 or now_ms - probed_at > probe_interval_ms)) {
            const probe_filters = [_]nostr.filter.Filter{.{ .kinds = &feed_kinds, .limit = 1 }};
            if (relay.subscribe(probe_sub, &probe_filters)) |_| {
                probe_at = now_ms;
                probed_at = now_ms;
            } else |_| {}
        }
        switch (msg.value) {
            .event => |e| {
                if (std.mem.eql(u8, e.subscription_id, "plaza-feed")) {
                    const store = g_store orelse continue;
                    // Verify (secp256k1) before storing; silently drop a bad event.
                    _ = store.ingest(gpa, e.event, .{ .verify_with = signer }) catch {};
                    // Note which relay carried it, so a thread can say how widely
                    // a note is held rather than guess.
                    if (e.event.kind == 1) markRelaySeen(noteIdOf(e.event), index);
                    // Note this feed post so its engagement can be watched. Bounded
                    // to keep the `#e` filter a size relays accept.
                    if (e.event.kind == 1 and feed_ids_len < engagement_watch_cap) {
                        const nid = noteIdOf(e.event);
                        var known = false;
                        for (feed_ids[0..feed_ids_len]) |fid| {
                            if (fid == nid) {
                                known = true;
                                break;
                            }
                        }
                        if (!known) {
                            feed_ids[feed_ids_len] = nid;
                            hexLower(&feed_id_hex[feed_ids_len], e.event.id);
                            feed_ids_len += 1;
                        }
                    }
                } else {
                    // The engagement subscription: fold into the counts, verified
                    // so a forged reaction cannot inflate a tally.
                    if (nostr.event.verify(gpa, signer, e.event) catch false) countEngagement(e.event, feed_ids[0..feed_ids_len]);
                }
            },
            .eose => |eo| {
                if (std.mem.eql(u8, eo.subscription_id, probe_sub) and probe_at != 0) {
                    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - probe_at;
                    if (elapsed >= 0) recordRelayRtt(index, @intCast(@min(elapsed, std.math.maxInt(u16))));
                    probe_at = 0;
                }
                // Stored feed drained: now watch those notes' engagement.
                if (!engagement_open and feed_ids_len > 0 and std.mem.eql(u8, eo.subscription_id, "plaza-feed")) {
                    engagement_open = true;
                    var evals: [engagement_watch_cap][]const u8 = undefined;
                    for (0..feed_ids_len) |i| evals[i] = &feed_id_hex[i];
                    const eng_kinds = [_]u16{ 1, 6, 7, 9735 };
                    const eng_tags = [_]nostr.filter.TagFilter{.{ .letter = 'e', .values = evals[0..feed_ids_len] }};
                    const eng_filters = [_]nostr.filter.Filter{.{ .kinds = &eng_kinds, .tags = &eng_tags }};
                    relay.subscribe("plaza-engagement", &eng_filters) catch {};
                }
            },
            else => {},
        }
    }
}

test {
    _ = @import("tests.zig");
}

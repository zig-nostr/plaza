//! App-wide numbers: layout metrics, caps, timers, effect keys and the image budget.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const Model = main.Model;
const handleUpdateChecked = main.handleUpdateChecked;
const comment_kind = main.comment_kind;
const feed_column_width = main.feed_column_width;
const verb_slot_height = main.verb_slot_height;

// The curated starter pack a newcomer follows on first run: a handful of
// well-known, active accounts so the feed is alive from the first second. The
// feed is scoped to these authors (plus the user's own notes); follow
// management and NIP-51 lists come later. Pubkeys are hex, decoded to bytes at
// comptime.
//
// EVERY NAME HERE IS A CLAIM ABOUT A REAL PERSON, and three of them were wrong
// for months: this list said Vitor, hodlbod and Lyn Alden, and the keys beside
// those names belong to PABLOF7z, Lyn Alden and Vitor Pamplona. hodlbod was
// never in the pack at all. The keys were always fine, so nobody followed
// anybody they should not have; the app simply told them the wrong thing about
// who they were reading, on the one screen a newcomer has no way to check.
//
// So the bar for editing this list: resolve the key's own NIP-05 at the domain
// it names and paste what THAT says. Not a kind:0, which anybody can write
// about themselves, and not memory, which is how this happened. Verified that
// way on 2026-08-19, every one of the nine.
//
// Nothing here can be tested locally. A comment and a hex string have no
// mechanical link, and no assertion in this repo can tell you whose key that
// is. The check is a person doing the lookup above, which is why the method is
// written down instead of a guard that would only look like one.
const starter_pack_hex = [_][]const u8{
    "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", // fiatjaf, _@fiatjaf.com
    "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2", // jack, jack@primal.net
    "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245", // jb55, _@jb55.com
    "04c915daefee38317fa734444acee390a8269fe5810b2241e5e6dd343dfbecc9", // ODELL, odell@primal.net
    "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93", // Gigi, dergigi.com
    "84dee6e676e5bb67b4ad4e042cf70cbd8681155db535942fcc6a0533858a7240", // Edward Snowden, Snowden@Nostr-Check.com
    "fa984bd7dbb282f07e16e7ae87b26a2a7b9b90b7246a44771f0cf5ae58018f52", // PABLOF7z, _@f7z.io
    "eab0e756d32b80bcd464f3d844b8040303075a13eabc3599a762c9ac7ab91f4f", // Lyn Alden, lyn@primal.net
    "460c25e682fda7832b52d1f22d3d22b3176d972f60dcdc3212ed8c92ef85065c", // Vitor Pamplona, _@vitorpamplona.com
};
pub const starter_pack = blk: {
    var pks: [starter_pack_hex.len][32]u8 = undefined;
    for (starter_pack_hex, 0..) |h, i| {
        _ = std.fmt.hexToBytes(&pks[i], h) catch unreachable;
    }
    break :blk pks;
};

// How many notes the feed asks the store for at first, and how many more each
// time the reader reaches the end. There is no ceiling: the list is windowed, so
// holding more notes costs memory rather than frames, and the buffer that holds
// them grows on demand.
//
// It used to stop at three hundred. Nothing about the rendering needed that; the
// number was the size of a fixed array, and a reader who scrolled to the bottom
// of it simply found that the feed ended.
pub const feed_page = 60;
/// What the feed asks a RELAY for, which is not the same question as how many
/// notes it can hold. A filter's limit is what a relay volunteers on subscribe,
/// and asking a stranger's relay for an unbounded backlog is how a client gets
/// rate limited. Older notes come from asking again with `until`, not from one
/// enormous number here.
pub const feed_request_limit = 300;
// A thread's replies are cached in the model (pressable, their pictures
// fetched), so this bounds that buffer. `thread_depth_max` bounds the
// open-as-a-sub-thread back-stack, and its ceiling is the SDK's virtual-window
// budget: every mounted level is a virtualList and the SDK tracks at most 8
// virtual windows per build (excess lists are silently dropped, and the LAST
// built (the visible thread) is the one that breaks). The feed plus six
// ancestors plus the current level is exactly eight.
pub const thread_reply_cap = 100;
/// How many of a person's notes one step of their page reads from the store, and
/// how many more each time the reader reaches the end of the list.
///
/// A page and the thread cap are the same number on purpose: the first read has
/// always been this many, and a person's page opens exactly as it did.
pub const profile_page = thread_reply_cap;
/// What a relay is asked for per page of older notes. One page, so that every
/// row it returns fits the engagement query that follows it (`engagement_watch_cap`).
/// Jumble asks for 200 (NoteList/index.tsx:49); it has no such query to fit.
pub const profile_relay_page = 100;
/// The most notes one person's page holds. The buffer grows on demand, and a
/// ceiling is what keeps a very prolific account from growing it without limit.
/// The page says so when it is reached, rather than pretending to be the end.
pub const profile_notes_max = 1500;
/// A tab with fewer rows than this keeps asking for older notes by itself.
/// "Notes" and "Replies" split ONE stream, so a person who mostly answers has a
/// short Notes tab that never scrolls, and a list that cannot scroll never
/// reaches its end to ask.
pub const profile_fill_rows = 30;
/// How many pages one visit fetches by itself to fill a short tab. Past it the
/// reader scrolls to ask, so an account with no replies at all cannot walk its
/// whole history for a tab that will stay empty.
pub const profile_autofill_max = 5;
pub const thread_depth_max = 6;
// How long a thread shows loading skeletons before giving up if the reply fetch
// never signals completion (a relay that never sends EOSE), so a reply-less note
// never stalls under skeletons forever.
pub const thread_loading_grace_s = 6;
// How much of a note's text is stored. A long note is collapsed in the feed to
// `note_collapse_chars` with a "Show more" that reveals the rest, up to this cap
// (a kind:1 past it is truncated: long-form is kind:30023, not a note).
//
// This was 1024, which is under an ordinary long note: a release announcement
// with a feature list runs 1500 to 2500 bytes, and "Show more" opened onto a
// note that stopped mid-sentence anyway. The cap was invisible in the UI because
// the text simply ended, so it read as a rendering bug rather than a limit.
//
// 4096 rather than more because `Note` carries its text inline and lives 100
// deep in a thread. Anything past a few kilobytes is long-form (kind:30023),
// which is a different surface, not a bigger note.
pub const note_content_cap = 4096;
pub const note_collapse_chars = 300;
// How many loaded notes each relay watches for engagement. Bounded so the
// `#e` filter stays a size relays accept; covers the feed's first screens.
pub const engagement_watch_cap = 128;
// The cap on that filter's answer. Without one the relay picks, and 128 note
// ids across four kinds is a very large thing to leave a busy relay to pick.
pub const engagement_request_limit = 500;
// What an engagement query asks for: replies, reposts, likes, zap receipts.
pub const engagement_kinds = [_]u16{ 1, comment_kind, 6, 7, 9735 };
// How often the feed's engagement subscription may be widened as more notes
// load. A REQ under an existing id replaces it, so widening is one message, but
// a busy feed adds ids continuously and re-asking on each one would be its own
// flood.
pub const engagement_widen_ms: i64 = 5_000;
// The composer's fixed text capacity. The display buffer
// (`Note.content_buf`) truncates for rendering, but the published event carries
// the full draft.
//
// It was 512, which is not "comfortably longer than a typical note": it is
// shorter than an ordinary announcement. Past it the buffer silently dropped
// what would not fit while the footer said "no length limit", so a paste came
// back cut mid-sentence with nothing on screen admitting it.
//
// This comment used to go on to blame that for the scrambled composer in #165,
// on the theory that the editor's own copy and this one disagreed and re-wrapped
// differently on the same frame. That is not established. #165 was filed the
// same day and says plainly that raising the cap left the scrambling exactly as
// it was, and the scramble has not been reproduced since, under the harness or
// in use. Two bugs that looked like one, and the guess is removed rather than
// left here to be read as a finding.
//
// The silent-dropping half is real and is NOT solved by a bigger number: it
// moved the wall from 512 to 4096. What fixes it is saying so, which is what
// `draft_dropped` is for.
pub const compose_capacity = 4096;
/// The profile editor's "about" box.
pub const profile_about_capacity = 280;
pub const refresh_timer_key: u64 = 1;
pub const refresh_interval_ms: u64 = 1_000;
// Wanted-profile fetching runs on its own cadence, decoupled from the view
// refresh: an author's name and avatar do not need per-second freshness, and a
// separate engine timer is the seam a future data-plane extraction cuts along.
pub const profile_timer_key: u64 = 3;
pub const profile_interval_ms: u64 = 2_000;
// The app version shown in Settings, from app.zon, which is where the packaged
// app gets its own. It used to be a second copy here with a comment asking
// whoever cut a release to remember: by 0.2.2 Settings was still saying 0.1.0.
// A number that has to be kept in step by hand is a number that drifts.
pub const plaza_version = @import("window_floor").manifest_version;
// Owner-only permissions for the files holding secrets. POSIX gets 0600;
// Windows has no mode bits (its permissions are file ATTRIBUTES), so it takes
// the default there and inherits the profile directory's access control.
pub const secret_file_permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
    .default_file
else
    std.Io.File.Permissions.fromMode(0o600);
// Effect keys for the two Settings clipboard copies (npub, nsec). Clipboard
// effects share the effect key space, so these stay distinct from the timer key.
pub const copy_npub_key: u64 = 100;
pub const copy_nevent_key: u64 = 103;
pub const copy_nprofile_key: u64 = 105;
pub const copy_note_text_key: u64 = 104;

pub const refused_draft_clip_key: u64 = 106;

pub const copy_refused_reply_key: u64 = 106;
// The update check. One at a time, so one key rather than a base.
pub const update_check_key: u64 = 110;
// Image fetches use effect keys `<base> + slot`, kept clear of the timer and
// clipboard keys above.
pub const avatar_fetch_key_base: u64 = 1000;
pub const media_fetch_key_base: u64 = 2000;
// NIP-05 well-known verification fetches, keyed `<base> + profile slot`.
pub const nip05_fetch_key_base: u64 = 3000;
// NIP-05 lookups typed into the search field, keyed `<base> + (sequence % count)`
// so each one has a key of its own and an answer can be told from the answer to
// the lookup before it. Far above every range here: verification alone runs from
// its base to its base plus `profile_cap`.
pub const nip05_lookup_key_base: u64 = 0x0500_0000;
pub const nip05_lookup_keys: u64 = 64;
pub const link_fetch_key_base: u64 = 4000;
// Warming: the same bytes, fetched for a row that is NOT on screen yet, and
// written to the disk cache without claiming a registry id. See `warmAhead`.
pub const avatar_warm_key_base: u64 = 6000;
pub const media_warm_key_base: u64 = 7000;

// The profile cache holds display names and avatars keyed by pubkey. It must be
// larger than the biggest on-screen author set marked in a single avatar pass
// (a full thread: the active user + the root + up to `thread_reply_cap` replies)
// with headroom for recently-seen authors, so the mark pass never has to evict
// an author it just marked. Names are cheap; only avatars are slot-bound.
// 4096, and it costs nothing. Measured at the 2048-follow ceiling with the
// follow-list walk removed: 3714us at 256, 3743us at 1024, 3627us at 4096,
// which is one number three times inside noise.
//
// It used to cost a great deal (6018us at 160 rising to 26258us at 4096) and
// the reason was not the cache. `refreshProfiles` derived its LMDB query limit
// from this constant, so growing the cache grew a database read that ran on
// every feed rebuild. Two unrelated quantities sharing one name.
//
// The index is twice the capacity, because an open-addressed table at full load
// degrades to a linear scan.
//
// The research said to raise this to 4096, citing Jumble's 5000. That is wrong
// FOR THIS CODEBASE and the measurement says so: several paths walk the whole
// array once per feed rebuild, so the cost is linear in this number. At the
// 2048-follow ceiling the rebuild measured 6018us at 160, 9499us at 256,
// 12213us at 512 and 16259us at 2048, against a 16000us frame. Jumble can hold
// 5000 because its cache is a hash map, not an array anything scans.
//
// 256 buys real headroom over a screenful of notifications for 3.5ms, and stops
// there. The right way to earn more is to stop upserting every follow into an
// LRU sized for on-screen authors, which is its own piece of work.
pub const profile_cap = 4096;

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
pub const chrome_inset: f32 = 16;
pub const rail_gap: f32 = 8;
/// The scope title (13.5) and the mono metadata register (10.5), as multipliers
/// of the 14.5 body, since the size enum only steps by one.
pub const scope_title_scale: f32 = 13.5 / 14.5;
// 11b's profile geometry.
pub const profile_banner_height: f32 = 132;
pub const profile_avatar_size: f32 = 72;
/// How far the face rides up over the banner's lower edge.
pub const profile_avatar_lift: f32 = 30;
pub const profile_name_scale: f32 = 19.0 / 14.5;
pub const profile_bio_line_height: f32 = 22;
pub const profile_links_height: f32 = 28;
/// Everything in the person card that is not the banner or the wrapping bio.
pub const profile_card_chrome: f32 = 190;
/// One quiet line, the height of a short row.
pub const quiet_row_extent: f32 = 56;
// 11c's Settings geometry: a 440 column, a 38px header band, and the section
// rhythm (16 between sections, 8 from a label to its card).
pub const settings_column_width: f32 = 440;
/// The padding a bare `.card` injects when `padding` is left unset, which is
/// what `modalCard` does: zero IS the unset sentinel, so a card that states no
/// padding gets the house inset rather than none.
const modal_card_inset: f32 = 24;
/// How wide the content of a settings card actually is: the column, less the
/// section card's 12 either side. Derived rather than measured, so moving one
/// moves the other, and held against the real layout by a test.
///
/// It used to subtract a modal card's house inset and the sheet's own 18 either
/// side as well. Settings is a page now: there is no modal card and no sheet
/// margin, and leaving those terms in would have quietly narrowed every row by
/// 84 points against a layout that no longer had them.
pub const settings_content_width: f32 = settings_column_width - 12 * 2;
pub const settings_header_height: f32 = 38;
pub const settings_section_gap: f32 = 16;
pub const settings_label_gap: f32 = 8;
pub const settings_card_radius: f32 = 11;
pub const settings_title_scale: f32 = 13.0 / 14.5;
pub const mono_meta_scale: f32 = 10.5 / 14.5;
/// The status bar's 11.5px register, and the menus' 12 / 12.5 / 11 / 9.5.
pub const status_scale: f32 = 11.5 / 14.5;
pub const menu_scale: f32 = 12.5 / 14.5;
pub const mono_row_scale: f32 = 11.5 / 14.5;
pub const mono_hint_scale: f32 = 11.0 / 14.5;
pub const mono_badge_scale: f32 = 9.5 / 14.5;
/// The focal note's own register (16.5 against the 14.5 body), the stats line's
/// 12.5, and the 4px each thread block sits in from the reading column's edge.
pub const focal_body_scale: f32 = 16.5 / 14.5;
pub const stat_scale: f32 = 12.5 / 14.5;
pub const thread_inset: f32 = 4;
/// The focal note minus its body: the 16 above, the identity block, the two 9px
/// steps, the exact-time line, the stats row and the verb row. Calibrated against
/// the running app, like the feed's own chrome.
pub const focal_row_chrome: f32 = focal_leading_pad + avatar_size + 9 + 9 + 20 + 12 + 34 + 35;
/// The reply field's row, which does not change shape with the thread.
pub const reply_row_extent: f32 = 62;
/// A nested reply's register: a smaller disc, a 13px name, a 13.5 body and 11.5
/// metadata, all one step under the reply it answers.
pub const nested_avatar_size: f32 = 28;
pub const nested_name_scale: f32 = 13.0 / 14.5;
pub const nested_body_scale: f32 = 13.5 / 14.5;
/// How much of the answered note the reply line shows before it elides.
pub const reply_context_snippet_chars: usize = 80;
pub const nested_meta_scale: f32 = 11.5 / 14.5;
pub const op_chip_scale: f32 = 9.0 / 14.5;
/// A nested reply minus its body, the branch line, and the show-more line, all
/// measured in the running app.
pub const nested_reply_chrome: f32 = 8 + 20 + 3;
pub const branch_more_extent: f32 = 6 + 22;
pub const show_more_extent: f32 = 12 + body_line_height + 10;
pub const outside_row_extent: f32 = 2 + body_line_height + 12;
/// The chain above the focal note: one compact row per ancestor, each hanging
/// off the rail that runs down to the note being read. The bottom pad IS the
/// rail's segment between two discs, so it is a layout number and an estimate
/// term at once.
pub const ancestor_top_pad: f32 = 14;
pub const ancestor_bottom_pad: f32 = 14;
pub const ancestor_identity_gap: f32 = 4;
/// An ancestor's body is clamped to two lines: the SDK has no multi-line clamp
/// (`TextOverflow.ellipsis` is single-line only), so the cut is made in the spans
/// before they are laid out. The column is the estimator's own 70 characters per
/// line at the 14.5 body, held to the 13.5 register.
pub const ancestor_body_lines: usize = 2;
/// A notification's preview, for the same reason and by the same rule.
pub const notification_body_lines: usize = 2;

/// How tall a `list_item` is when its content does not say. The toolkit used to
/// floor every list row at this, and Plaza's theme no longer lets it (see
/// `metrics.row_extent` in theme.zig), so a row that was sized by the floor
/// states it.
pub const list_row_height: f32 = 28;

/// The age under a notification, which is also the row's keyboard stop. One line
/// of the mono meta type.
pub const notification_age_height: f32 = 18.1;
/// A quote is an aside, so it shows four lines of the note it quotes and stops
/// (11f). Its height is then known where the row around it is priced.
pub const quote_body_lines: usize = 4;
/// What a quote still resolving reserves, so the row keeps its height when the
/// note lands.
pub const quote_skeleton_height: f32 = 34;
/// The depth-1 pill's own height, stated because a `list_item` floors at 28.
pub const quote_pill_height: f32 = 22;
/// A quote card's picture is a thumbnail of what is one press away, not a copy
/// of the feed's: this wide at most, and no taller than it is wide however tall
/// the picture is (a taller one is `contain`ed in a box of its own shape).
pub const quote_picture_width: f32 = 280;
pub const quote_picture_max_aspect: f32 = 1.0;
/// And no flatter than this, so a panorama is still a thing a press can land on.
pub const quote_picture_min_aspect: f32 = 0.3;
/// How wide the pill's one line may run before it elides, so a quoted note with
/// a lot to say cannot push the pill across the row.
pub const quote_pill_label_width: f32 = 190;
/// A picture and the chips over it (11o): the corner inset, the chip's own
/// height, and how much of each label may run before it elides. The alt chip is
/// given room for a phrase, the dimensions chip for `4032x3024`.
pub const picture_radius: f32 = 10;
pub const picture_chip_inset: f32 = 8;
pub const picture_chip_height: f32 = 18;
/// The chips' own 10px mono register, a rung below the metadata mono.
pub const mono_chip_scale: f32 = 10.0 / 14.5;
/// The picture's box: the reading column it spans, the aspect past which a very
/// tall picture is contained rather than taking over the feed, and the shape to
/// assume when the note says nothing and nothing has been decoded yet.
pub const picture_column_width: f32 = feed_column_width - row_pad_side * 2 - avatar_size - avatar_to_text_gap;
pub const picture_max_aspect: f32 = 1.25;
pub const picture_default_aspect: f32 = 0.66;
/// The composer sheet (11l): its width, the header band, and how tall the editor
/// stands before it scrolls (about eight lines of its own register).
pub const compose_sheet_width: f32 = 560;
/// The first-intent sheet, and the name card that can follow it. Different
/// widths on purpose: the sheet holds three choices and has to lay them out as
/// cards; the name card holds one field and one question, and a card that wide
/// around a single input reads as a form.
/// The join sheet's one width, for the dialog AND for every card inside it.
///
/// They used to differ (a 420 dialog around a 372 card) and the 48pt band
/// between them belonged to neither: the card absorbs presses and the backdrop
/// dismisses, so a press in the band dispatched nothing and reached the feed
/// underneath, which opened whatever it landed on. A dialog wider than its card
/// is a hole through the modal, so there is one number now.
pub const join_sheet_width: f32 = 420;
pub const name_card_width: f32 = 340;
/// The two other modal card widths, named because a `.dialog` now needs its
/// width stated: the SDK centres a modal at its preferred size and falls back to
/// a 420pt default, which silently clamped the profile card's 400 + 16 padding.
pub const profile_edit_card_width: f32 = 400;
pub const join_title_scale: f32 = 17.0 / 14.5;
pub const join_sub_scale: f32 = 11.5 / 14.5;
pub const join_label_scale: f32 = 9.0 / 14.5;
pub const join_card_title_scale: f32 = 13.5 / 14.5;
pub const join_card_sub_scale: f32 = 11.0 / 14.5;
pub const name_title_scale: f32 = 14.5 / 14.5;
const compose_header_height: f32 = 38;
/// How wide the note field actually is: the column, less the card's 14 either
/// side, less the avatar and the 12 beside it.
///
/// STATED, not inherited, and that is the whole point. A text element measures
/// at its natural width whatever its ancestors say, so a field that takes its
/// width from a `grow` parent wraps for LAYOUT at one width and measures for
/// PAINT at another, and two wrappings of the same paragraph land on the same
/// rows. That was once blamed for a pasted note drawing scrambled (#165); it was
/// not the cause, which turned out to be CR line breaks (see `plainLineBreaks`).
pub const compose_editor_width: f32 = compose_sheet_width - 14 * 2 - avatar_size - 12;
pub const compose_editor_height: f32 = 150;
// Three lines of room in the thread's reply box, plus its 14pt padding. Enough
// that a paragraph does not scroll before it is finished, small enough that the
// note being answered stays on screen above it, which is the reason to reply in
// the thread rather than in the composer.
pub const reply_editor_height: f32 = 88;
/// How many bands a striped placeholder may draw. A tall picture would otherwise
/// spend fifty widget nodes on a fill nobody reads, against a 1024-node ceiling
/// that refuses the whole view when it is crossed.
pub const picture_stripe_cap: usize = 24;
/// The off-state chip's own height.
pub const picture_ask_height: f32 = 24;
/// The chip that stands in for a note while its author's content warning is up.
/// One line, a little taller than the picture-ask chip because it stands in for
/// the whole body rather than annotating a picture under it.
pub const cover_notice_height: f32 = 28;
/// A link card, with and without a description. Its TEXT column sets the height,
/// not its 30px tile: the domain, title and description each take a full body
/// line box whatever register they are set in (a span scaled down keeps the line
/// it is given). MEASURED, like every other row constant here, because summing
/// the parts is what got the last three wrong.
pub const link_card_height: f32 = 77.125;
pub const link_card_height_bare: f32 = 57;
/// A quote's aside minus its body lines: the 5 above it, the 2 either side, the
/// identity block beside the disc and the gaps between the column's three
/// children. MEASURED in the running layout rather than summed from those parts,
/// the way every other row constant here now is, because summing them was wrong
/// by a line and a half and nothing said so.
pub const quote_aside_chrome: f32 = 62.125;
/// The same for a quote that has not arrived, or never will: the 5 above it, the
/// column's sibling gap and the 2px pads, and NO identity block, because those
/// states draw a bar or a single line where the identity would be.
pub const quote_quiet_chrome: f32 = 5 + 4 + 2 + 2;
pub const ancestor_chars_per_line: usize = @intFromFloat(70 / nested_body_scale);
/// A nested line, at the height it now actually draws.
///
/// This used to be `body_line_height`, with a comment explaining that a body
/// line is a body line whatever register it is set in: `textSpansMaxScale`
/// starts at 1 and only takes the max, so a paragraph whose spans were all
/// scaled DOWN still got a full `14.5 * 1.25` box. That was a true description
/// of the engine and a workaround for a defect, and pricing around it kept the
/// defect: the glyphs shrank and the line box did not, so every nested line sat
/// a point low with a point and a quarter of air above it.
///
/// The nested register is asked for by its SIZE now (`.sm`, which is
/// `body_size - 1`), so the box is the one the text needs and the estimate is
/// the height it draws.
pub const ancestor_line_height: f32 = nested_line_height;
pub const ancestor_row_chrome: f32 = avatar_size + ancestor_identity_gap + ancestor_bottom_pad;
/// A ghost row: its two quiet lines set the height, not the dashed disc. Both are
/// scaled down and both still take a full body line box (see
/// `ancestor_line_height`), which puts the text column past the 36px disc.
pub const ghost_row_extent: f32 = 2 + body_line_height + 3 + body_line_height + ancestor_bottom_pad;
/// The one quiet line above a reply whose parent is not in the set, plus the
/// gap under it. Priced here because the block's extent estimate has to include
/// it or the windowed list sizes the row short and the reader sees it jump.
pub const orphan_note_extent: f32 = body_line_height + 6;
/// The listening footer, and the focal note's own leading space when it is the
/// first row (an ancestor's bottom pad provides it otherwise).
pub const listening_row_extent: f32 = 8 + 1 + 10 + body_line_height + 10;
pub const focal_leading_pad: f32 = 16;
/// One wrapped body line, as the engine actually lays it out (`size * 1.25` at a
/// 14.5 body). Measured live, and the estimator's unit.
pub const body_line_height: f32 = 18.125;
/// The same for the nested register, which is `.sm` (`body_size - 1`) and so
/// lays out at `13.5 * 1.25`.
pub const nested_line_height: f32 = 16.875;
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
pub const thread_reply_chrome: f32 = thread_row_pad + avatar_size + 5 + 5 + engagement_row_height + thread_row_pad + 1;
pub const thread_skeleton_extent: f32 = 76;
pub const meta_scale: f32 = meta_size / 14.5;
/// The name: 14px, one step under the body, in the medium face. The mock asks for
/// 600 and the bundled family steps 400 / 500 / 700, so medium is the nearer rung.
pub const name_scale: f32 = 14.0 / 14.5;
/// The engagement strip's measured height: the count's line box, which is taller
/// than the 15px glyphs beside it. It was 28 while the verbs were `.list_item`s,
/// a kind that carries an intrinsic 28px row-height floor; they are plain
/// pressable rows now, so the strip measures what it draws.
pub const engagement_row_height: f32 = verb_slot_height;
/// A feed row minus its body: the insets, the identity block pinned to the disc,
/// the two vertical steps, the verbs, and the hairline. Every term is the
/// redesign's own number, so the estimate cannot drift from the layout.
pub const feed_row_chrome: f32 = row_pad_top + avatar_size + 5 + 10 + engagement_row_height + row_pad_bottom + 1;

/// How many pictures the app can be showing at once.
///
/// A POLICY cap inside the shared pool, not a reserved share of it: a screen of
/// two four-picture notes plus a three-picture one is what a Nostr feed
/// actually looks like, and the old six was a reservation that made the fourth
/// picture of the second note impossible however idle the rest of the registry
/// was. The registry still decides how many of these hold pixels at once.
pub const max_media_images = 12;

/// A span of feed rows, inclusive at both ends. Named rather than anonymous so
/// the visible span and the warmed span are the same type and one can be built
/// from the other.
pub const RowRange = struct { first: usize, last: usize };

/// How many rows either side of the viewport are warmed into the disk cache.
///
/// Not a registry budget: warming claims no image id, so this is bounded by
/// bandwidth and by the per-tick fetch ceilings, not by the sixteen slots. Eight
/// is about a screen either way at the feed's row height, which is the distance
/// a flick covers before the next tick can react.
pub const feed_prefetch_rows: usize = 16;
/// What a banner is asked for and bounded to.
///
/// 512 and not a pixel more: `decodeAndRegister` scales the LONG edge to this,
/// so the worst case it can produce is `max_dim` squared, and 512x512x4 is
/// exactly the registry's 1 MiB ceiling. A larger number here would refuse
/// every banner a reader happens to have uploaded square. The band draws 660x132,
/// so this is about 1.7x on the long edge, which is the honest ceiling: 2x would
/// be 1320x264 and 1.33x over the cap.
pub const banner_target_px: u32 = 512;
// What each image is requested at. Avatars draw at 40pt, so asking for more
// than a couple of hundred pixels is pure waste. Feed images are bounded as a
// BOX, not just a width: the registry's budget is 1 MiB of decoded pixels, so a
// 512-wide image that happens to be tall (512x717 is a real example) still
// blows it. 480x480 leaves honest headroom under the cap.
pub const avatar_target_px: u32 = 128;
pub const media_target_px: u32 = 480;
// The largest body we accept from ONE fetch. The effect caps at 256 KiB anyway;
// stopping a little short keeps the decode budget for images that will fit.
pub const max_image_bytes = 240 * 1024;
// The largest picture we will assemble out of several of those.
//
// A response body is capped at `max_image_bytes`, and an ordinary phone photo
// is several times that: every picture in a Nostr feed shot on a phone is
// 300 KB to 2 MB, so "one body" was never a size a photo fits in. A picture
// over it is asked for in slices (HTTP Range) and reassembled here.
//
// The ceiling is a real refusal, not a formality: bytes arriving from a
// stranger's host are held whole in memory before they decode, so something
// has to say when to stop. Four MiB covers a full-frame camera JPEG and
// refuses a file that is not a feed picture at all.
pub const max_image_download_bytes = 4 * 1024 * 1024;
// The registry's own ceiling on one decoded image.
pub const max_registered_image_bytes = 1024 * 1024;
// Animated GIFs decode every frame up front, so they are bounded twice over: by
// frame count and by total decoded bytes. An animated GIF is asked for at this
// smaller size, since it has to arrive whole inside the fetch cap.
pub const gif_target_px: u32 = 240;
pub const max_gif_frames = 64;
pub const max_gif_total_bytes = 24 * 1024 * 1024;
// How many play at once, and how often the shared animation timer ticks.
pub const max_playing_gifs = 2;
pub const animation_interval_ms: u32 = 80;
pub const animation_timer_key: u64 = 2;

pub const plaza_version_for_test = plaza_version;
pub const settings_column_width_for_test = settings_column_width;
pub const settings_content_width_for_test = settings_content_width;
/// The same number, for a test that has to know where a row's disc lands.
pub const thread_inset_for_test: f32 = thread_inset;
pub const picture_column_width_for_test: f32 = picture_column_width;
pub const compose_editor_width_for_test = compose_editor_width;
pub const reply_editor_height_for_test = reply_editor_height;
pub const link_card_height_for_test: f32 = link_card_height;
pub const link_card_height_bare_for_test: f32 = link_card_height_bare;
/// Makes room for `n` notes and re-points `model` at the grown buffer. For tests
/// that fill the feed by hand rather than through the store: the app grows on
/// its way through `rebuildNotes`, and writing past the end without that is the
/// out-of-bounds it should be.
/// One more page, the way the reader's scroll asks for it. For tests, so they
/// page down through the real path rather than setting the limit by hand.
pub fn loadOlderForTest(model: *Model) void {
    model.feed_limit += feed_page;
}
pub fn updateNewsForTest(body: []const u8) void {
    handleUpdateChecked(.{ .key = update_check_key, .outcome = .ok, .status = 200, .body = body, .truncated = false, .dropped_before = 0 });
}
pub const feed_prefetch_rows_for_test = feed_prefetch_rows;
pub const gif_target_px_for_test = gif_target_px;
pub const media_target_px_for_test = media_target_px;
pub fn maxMediaImagesForTest() usize {
    return max_media_images;
}

pub const quote_picture_width_for_test = quote_picture_width;

pub fn maxImageBytesForTest() usize {
    return max_image_bytes;
}

pub fn maxImageDownloadBytesForTest() usize {
    return max_image_download_bytes;
}
/// The same, recording where each mention's label landed into `mentions` when
/// one is given. A note wants that table so the label can be pressed; a profile's
/// "about" text is rendered the same way and has nowhere to put one.
pub const note_content_cap_for_test = note_content_cap;
pub fn noteContentCapForTest() usize {
    return note_content_cap;
}
pub const compose_capacity_for_test = compose_capacity;
pub fn starterPackLenForTest() usize {
    return starter_pack.len;
}
pub const ghost_row_extent_for_test = ghost_row_extent;
pub const listening_row_extent_for_test = listening_row_extent;
pub const outside_row_extent_for_test = outside_row_extent;
pub const show_more_extent_for_test = show_more_extent;
pub const ancestor_row_chrome_for_test = ancestor_row_chrome;
/// Opens, or replaces, the engagement subscription over the first `count`
/// watched notes.
///
/// A REQ under an existing id IS a replacement, so widening the watched set
/// costs one message and no CLOSE.
/// Records a feed note's id so its engagement can be watched, deduped and
/// bounded.
///
/// Shared by the pool threads and the routed ones, because they had drifted:
/// the pool watched engagement and the routed relays did not, and after the
/// outbox landed the routed relays are the ones carrying most of the feed. One
/// function is what stops that happening again.
///
/// The cap keeps the `#e` filter a size relays actually accept.
pub const engagementWatchCapForTest = engagement_watch_cap;

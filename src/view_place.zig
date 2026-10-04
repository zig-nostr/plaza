//! A place's header, home, info card, logo, and the scope bar.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const follows = @import("follows.zig");
const places = @import("places.zig");
const prefs = @import("prefs.zig");
const profile_cache = @import("profile_cache.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Effects = main.Effects;
const Model = main.Model;
const Msg = main.Msg;
const Place = main.Place;
const abbreviateNpub = main.abbreviateNpub;
const acquireImageId = main.acquireImageId;
const activePlace = main.activePlace;
const chrome_inset = main.chrome_inset;
const copyBounded = main.copyBounded;
const currentPlaceFeed = main.currentPlaceFeed;
const decodeAndRegister = main.decodeAndRegister;
const directAllowed = main.directAllowed;
const elide = main.elide;
const feed_column_width = main.feed_column_width;
const fetchSlice = main.fetchSlice;
const followTotalOwned = main.followTotalOwned;
const hgap = main.hgap;
const homeReadsPack = main.homeReadsPack;
const homeScopeSwitchable = main.homeScopeSwitchable;
const join_sub_scale = main.join_sub_scale;
const join_title_scale = main.join_title_scale;
const loadCachedImage = main.loadCachedImage;
const max_image_bytes = main.max_image_bytes;
const mediaUrl = main.mediaUrl;
const menuRow = main.menuRow;
const menuSurfacePlaced = main.menuSurfacePlaced;
const modalCard = main.modalCard;
const modalScrim = main.modalScrim;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const outboxZone = main.outboxZone;
const placeLink = main.placeLink;
const pressRow = main.pressRow;
const proxyRefusedHost = main.proxyRefusedHost;
const relayHost = main.relayHost;
const relayZone = main.relayZone;
const rememberProxyRefusal = main.rememberProxyRefusal;
const scope_title_scale = main.scope_title_scale;
const signerZone = main.signerZone;
const statusChip = main.statusChip;
const storeCachedImage = main.storeCachedImage;
const vgap = main.vgap;

/// The feed's scope line: which feed this is (the starter pack) and how wide it
/// reaches. A property of the feed, not a destination to choose between.
/// The header of the place you are in: who it belongs to, what they wrote, and
/// the way out.
///
/// While VISITING it also carries the one affordance that matters, and it is a
/// quiet line rather than a wall: entering keeps the place, and nothing else in
/// the app is gated on it. You can already read here and post here.
///
/// It says entering is private on the spot rather than in settings, because a
/// list of the communities somebody belongs to is sensitive and they should
/// learn that where the decision is, not afterwards.
/// How much of a stranger's naming fits on the room's one header line.
///
/// The line is the name, the connection state, the feed's name, About and the
/// verb, all inside the 620pt column with 16pt insets. The app's own strings
/// and the two buttons are the budget; the two names arrive from a place a
/// stranger published, at 64 and 48 bytes, and both of them at full length
/// overflowed the window by 240pt at its floor.
///
/// These came down when Info joined the row: the overflow sweep measures the
/// worst case (longest name, longest feed name, "cannot reach this place",
/// Info and Enter together) and it was 20pt over at the floor.
///
/// Named for the LINE, not for the place: `place_name_cap` and
/// `place_feed_name_cap` are what the buffers hold (64 and 48), and these are
/// what one header line can show of them.
const header_name_cap = 20;
const header_feed_cap = 14;

/// The width of the Info card. Wide enough for a paragraph of somebody's
/// markdown without becoming a page.
const place_info_card_width: f32 = 620;

/// How tall the host's own text may be inside that card before it scrolls.
///
/// The card had no bound at all, and nothing showed it until a place arrived
/// with a real `homeMarkdown`: headings and a couple of lists grow a dialog
/// TALLER THAN THE WINDOW, and what falls off the bottom edge is the footer:
/// Close, and Leave. A reader who wants out of a place is exactly the reader
/// looking for those, and they were unreachable.
///
/// A scroll region rather than a shorter excerpt, because Info is the surface
/// where the WHOLE text belongs; cutting it is the welcome's job, not this one.
/// The most of a host's welcome that is shown before it scrolls.
const place_info_home_max: f32 = 380;

/// The place's own mark, drawn in its Info card.
///
/// A much smaller pipeline than the profile banner's, on purpose. That one
/// slices a body too big for one response, falls back off the proxy when a host
/// refuses it, and buffers the pieces. A logo is a small square from a site the
/// community chose: if it does not arrive whole, first time, there is no logo
/// and the card is fine without one.
pub var g_place_logo_id: u64 = 0;
/// Which place's logo is loaded, so walking into another room does not leave
/// the last community's mark on screen.
///
/// Host AND `d`, the pair that identifies a place everywhere else in this file.
/// The host alone is not a place: one community can run several rooms, and they
/// do not share a mark.
pub var g_place_logo_for: [32]u8 = @splat(0);
pub var g_place_logo_for_ident_buf: [64]u8 = @splat(0);
pub var g_place_logo_for_ident_len: u8 = 0;
/// Which place the in-flight fetch was started FOR, which is not always the
/// place on screen by the time it lands. `g_banner_asked_for` carries this for
/// faces, for the same reason and with the same consequence if it is missing.
pub var g_place_logo_asked_for: [32]u8 = @splat(0);
pub var g_place_logo_asked_ident_buf: [64]u8 = @splat(0);
pub var g_place_logo_asked_ident_len: u8 = 0;
pub var g_place_logo_state: enum { idle, fetching, loaded, failed } = .idle;
/// The pass this logo was last on screen. The pool may not take a slot that is
/// being looked at, and it only knows that because this is stamped every pass a
/// place is open.
pub var g_place_logo_seen: u64 = 0;

pub const place_logo_fetch_key: u64 = 5200;
const place_logo_px: u32 = 96;

/// Drops the mark on screen and hands its slot back to the pool.
///
/// Every exit from a room goes through here: leaving for your own feed, and
/// walking straight into a different room. The second one is the one that was
/// missing, and a logo is not the kind of state that can be left to be
/// overwritten later, because the next room may have nothing to overwrite it
/// with.
fn forgetPlaceLogo(fx: *Effects) void {
    if (g_place_logo_id != 0) {
        _ = fx.unregisterImage(g_place_logo_id);
        g_place_logo_id = 0;
    }
    g_place_logo_for = @splat(0);
    g_place_logo_for_ident_len = 0;
    g_place_logo_state = .idle;
    // Another room's mark is another host, so it goes through the proxy first.
    g_place_logo_direct = false;
}

/// Whether the room's mark is fetched from its own host, because the proxy
/// refused that host and the reader allows the fallback. The banner's rule.
pub var g_place_logo_direct: bool = false;

/// The address the room's mark is fetched from: through the reader's proxy,
/// at the size it is drawn, like every other picture. It went to the host
/// itself, raw, whatever the proxy setting said.
fn placeLogoUrl(buf: []u8, logo: []const u8) []const u8 {
    if (directAllowed(logo, g_place_logo_direct)) return logo;
    return mediaUrl(buf, logo, place_logo_px, .square);
}

pub fn placeLogoUrlForTest(buf: []u8, logo: []const u8) []const u8 {
    return placeLogoUrl(buf, logo);
}

pub fn placeLogoDirectForTest() bool {
    return g_place_logo_direct;
}

/// Hands the logo pipeline an answer with no body, the way the effect loop
/// does, for a test of a proxy refusing the host.
pub fn deliverPlaceLogoStatusForTest(fx: *Effects, status: u16) void {
    handlePlaceLogoFetched(fx, .{
        .key = place_logo_fetch_key,
        .outcome = .ok,
        .status = status,
        .body = "",
    });
}

/// Fetches the place's mark once, and forgets it when the reader leaves.
pub fn scanPlaceLogo(fx: *Effects, model: *const Model) void {
    _ = model;
    const place = activePlace() orelse {
        // Out of every room: the slot goes back to the pool rather than holding
        // a picture nobody can see. The feed underneath is what wants it.
        forgetPlaceLogo(fx);
        return;
    };
    // On screen this pass, so the allocator will not take the slot out from
    // under the reader. Stamped before any early return below: a logo that is
    // loaded and simply not being re-fetched still needs its slot kept.
    g_place_logo_seen = profile_cache.g_image_clock;

    // A different community is a different mark, and this is decided BEFORE any
    // return below can skip it. It used to sit under the two guards that follow,
    // so a room with no logo of its own took the early return and left the last
    // room's mark loaded and on screen: one community's logo on another
    // community's card, which is what was reported. Walking OUT of a room
    // already cleared it, so only walking room to room could show it.
    //
    // Compared by identity rather than by the URL: two places may ship the same
    // logo and still be different rooms.
    if (!std.mem.eql(u8, &g_place_logo_for, &place.author) or
        !std.mem.eql(u8, g_place_logo_for_ident_buf[0..g_place_logo_for_ident_len], place.ident()))
    {
        forgetPlaceLogo(fx);
        g_place_logo_for = place.author;
        g_place_logo_for_ident_len = @intCast(copyBounded(&g_place_logo_for_ident_buf, place.ident()));
        // Cleared above, so this pass is the new room's first: stamp it again or
        // the pool may take the slot this is about to ask for.
        g_place_logo_seen = profile_cache.g_image_clock;
    }
    if (!prefs.g_media_previews) return;
    const logo = place.logo();
    if (logo.len == 0) return;
    if (g_place_logo_state != .idle) return;

    if (g_place_logo_id == 0) {
        g_place_logo_id = acquireImageId(fx) orelse return;
    }
    if (loadCachedImage(fx, g_place_logo_id, logo, place_logo_px)) |_| {
        g_place_logo_state = .loaded;
        return;
    }
    g_place_logo_state = .fetching;
    // Stamped with the asker, next to the ask.
    g_place_logo_asked_for = place.author;
    g_place_logo_asked_ident_len = @intCast(copyBounded(&g_place_logo_asked_ident_buf, place.ident()));
    var url_buf: [1024]u8 = undefined;
    fetchSlice(fx, place_logo_fetch_key, placeLogoUrl(&url_buf, logo), 0, Effects.responseMsg(.place_logo_fetched));
}

pub fn handlePlaceLogoFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key != place_logo_fetch_key) return;
    const arrived_for = activePlace() orelse {
        g_place_logo_state = .idle;
        return;
    };
    // The body was asked for by a ROOM, and the reader can walk into a different
    // one while it is in flight. Painting it now would put one community's mark
    // on another community's card and, worse, cache it under the NEW room's URL
    // (`storeCachedImage` below keys on `place.logo()`), so the wrong logo would
    // come back on every later visit and every later launch. Set idle rather
    // than failed: this body is wrong, the room's own logo has not been tried.
    if (!std.mem.eql(u8, &g_place_logo_asked_for, &arrived_for.author) or
        !std.mem.eql(u8, g_place_logo_asked_ident_buf[0..g_place_logo_asked_ident_len], arrived_for.ident()))
    {
        g_place_logo_state = .idle;
        return;
    }
    // Every effect slot was busy: ask again next tick.
    if (response.outcome == .rejected) {
        g_place_logo_state = .idle;
        return;
    }
    // The proxy refusing the HOST: the source itself, once, and only while the
    // reader allows it. The same fallback faces and the banner take.
    if (prefs.g_media_direct_fallback and prefs.g_media_proxy_on and !g_place_logo_direct and
        proxyRefusedHost(response.outcome, response.status))
    {
        rememberProxyRefusal(arrived_for.logo());
        g_place_logo_direct = true;
        g_place_logo_state = .idle;
        return;
    }
    // 206 as well as 200. The fetch asks for a RANGE, so a server that honours
    // it answers Partial Content even when what came back is the whole file,
    // which is the usual case for something this small. Accepting only 200
    // threw a perfectly good logo away.
    //
    // No accumulator behind this: if a logo really is too big for one response,
    // the decode below fails and there is no logo, which is what this pipeline
    // promises. See `g_place_logo_id`.
    const usable = response.outcome == .ok and (response.status == 200 or response.status == 206);
    if (!usable or response.truncated or
        response.body.len == 0 or response.body.len > max_image_bytes)
    {
        g_place_logo_state = .failed;
        return;
    }
    if (decodeAndRegister(fx, g_place_logo_id, response.body, place_logo_px)) |_| {
        g_place_logo_state = .loaded;
        storeCachedImage(arrived_for.logo(), response.body);
    } else {
        g_place_logo_state = .failed;
    }
}

/// How wide the welcome may be inside the card.
///
/// The card is 620 and the welcome was laid out at 580, which put its left edge
/// where the padding says and ran its right edge onto the card's border. The
/// inset is 40 a side, not 20. Measured off what is drawn rather than derived
/// from the padding value, because what the reader sees is the thing that was
/// wrong.
const place_info_home_width: f32 = place_info_card_width - 80;

/// How tall the welcome needs to be, so a short one does not leave a void.
///
/// This was a fixed 380 and a two-line welcome sat above three hundred points
/// of nothing, with the Close button stranded at the bottom of an empty box.
/// There is no `max_height` on a canvas node, so the height has to be worked
/// out rather than declared.
///
/// An ESTIMATE, deliberately generous. Over-guessing costs a little scroll at
/// the end; under-guessing cuts the host's last line off, and of the two only
/// one loses somebody's words.
pub fn placeHomeHeight(text: []const u8) f32 {
    // At 540 points and this body size, about 72 characters fit on a line.
    // Read off a render at that width: the second paragraph of the welcome that
    // prompted all this wraps after 73.
    // Measured off a real render rather than guessed: the welcome that prompted
    // this wraps after 82 and its second paragraph fits 165 in two lines.
    const per_line: usize = 72;
    const line_height: f32 = 21;
    // Lines of text and gaps BETWEEN blocks are charged separately: the
    // renderer puts 12 points between blocks, not a blank line's worth, and
    // several blank lines in a row are still one break.
    const block_gap: f32 = 12;
    var lines: usize = 0;
    var breaks: usize = 0;
    var in_gap = true; // leading blanks are not a break
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const shown = visibleLen(line);
        if (shown == 0) {
            if (!in_gap) breaks += 1;
            in_gap = true;
            continue;
        }
        in_gap = false;
        lines += (shown + per_line - 1) / per_line;
    }
    // No slack on the end. This is a SCROLL, so guessing low costs a little
    // scrolling and guessing high leaves a void with the buttons stranded below
    // it, which is the bug this function exists for. I had that backwards once.
    const wanted = @as(f32, @floatFromInt(lines)) * line_height +
        @as(f32, @floatFromInt(breaks)) * block_gap;
    return @min(wanted, place_info_home_max);
}

/// How much of a markdown line a reader actually sees.
///
/// Counting raw bytes is what made the first estimate useless: one paragraph of
/// this welcome carries `[experimental customizeable client](/nevent1q…)`, and
/// that address is two hundred characters that are never drawn. The line looked
/// four times longer than it reads.
pub fn visibleLen(line: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    // Leading heading markers and quote marks are syntax, not text.
    while (i < line.len and (line[i] == '#' or line[i] == '>' or line[i] == ' ')) i += 1;
    while (i < line.len) {
        // `](url)` is an address. Skip to its closing paren.
        if (line[i] == ']' and i + 1 < line.len and line[i + 1] == '(') {
            if (std.mem.indexOfScalarPos(u8, line, i + 2, ')')) |end| {
                i = end + 1;
                continue;
            }
        }
        // The brackets and emphasis marks themselves are not drawn either.
        if (line[i] == '[' or line[i] == ']' or line[i] == '*' or line[i] == '`') {
            i += 1;
            continue;
        }
        n += 1;
        i += 1;
    }
    return n;
}
/// What a place is, who hosts it, where it reads from, and the way out.
///
/// Everything the old inline banner said, in a card nobody has to scroll past.
/// Leave lives here rather than in the header for two reasons: it is the one
/// destructive verb in a place and it was sitting a few pixels from Enter, and
/// a reader who is about to leave is exactly the reader who should be looking
/// at what this place is.
/// The host's own words, with image syntax carrying no alt text removed.
///
/// The renderer draws an image as its ALT TEXT, which is the right call for a
/// client that spends its whole image budget on faces. `![alt](url)` therefore
/// reads as "alt". But `![](url)`, which is valid markdown and what Hallway's
/// Monero instance writes, has no alt to draw: the renderer does not take it as
/// an image at all, so the reader gets a literal `![]` followed by the raw URL
/// as a link.
///
/// An image with no alt text says nothing that can be written down, so nothing
/// is what it should leave behind.
fn placeHome(ui: *AppUi, m: *const Place) []const u8 {
    return stripEmptyImages(ui.arena, m.home());
}
pub fn stripEmptyImages(arena: std.mem.Allocator, src: []const u8) []const u8 {
    if (std.mem.indexOf(u8, src, "![](") == null) return src;
    var out = std.ArrayList(u8).initCapacity(arena, src.len) catch return src;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "![](")) {
            // To the closing paren of the URL. An unclosed one is not image
            // syntax, so it is left exactly as the host wrote it.
            if (std.mem.indexOfScalarPos(u8, src, i + 4, ')')) |end| {
                i = end + 1;
                continue;
            }
        }
        out.append(arena, src[i]) catch return src;
        i += 1;
    }
    return out.items;
}

pub fn placeInfoCard(ui: *AppUi, m: *const Place) AppUi.Node {
    const p = theme.palette;
    const leaving = places.g_place_info == .leaving;
    var npub_buf: [96]u8 = undefined;
    const host = abbreviateNpub(&npub_buf, m.author);
    const relay = if (currentPlaceFeed(m)) |f| f.relay() else "";
    return modalScrim(ui, "About this place", .close_place_info, ui.el(.dialog, .{
        .width = place_info_card_width,
        .on_dismiss = .close_place_info,
        .semantics = .{ .label = "About this place" },
    }, .{
        modalCard(ui, place_info_card_width, ui.column(.{ .grow = 1, .gap = 0, .padding = 20 }, .{
            // The mark beside the name when the community ships one and it has
            // arrived. Nothing reserved for it otherwise: a gap where a logo
            // might have been is worse than a title on its own.
            if (g_place_logo_state == .loaded and g_place_logo_id != 0) ui.row(.{ .cross = .center, .gap = 10 }, .{
                ui.image(.{ .image = g_place_logo_id, .width = 28, .height = 28, .semantics = .{ .label = "Place logo" } }),
                ui.paragraph(
                    .{ .grow = 1, .wrap = true, .style = .{ .foreground = p.text_primary } },
                    &.{.{ .text = if (m.name_len > 0) m.name() else "A place", .weight = .bold, .scale = join_title_scale }},
                ),
            }) else ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = if (m.name_len > 0) m.name() else "A place", .weight = .bold, .scale = join_title_scale }},
            ),
            vgap(ui, 10),
            placeInfoRow(ui, "Host", ui.fmt("@{s}", .{host})),
            if (relay.len > 0) vgap(ui, 4) else ui.spacer(0),
            if (relay.len > 0) placeInfoRow(ui, "Reads", relay) else ui.spacer(0),
            // The host's own words, in the one place that is theirs to fill.
            if (m.home_len > 0) vgap(ui, 12) else ui.spacer(0),
            if (m.home_len > 0) ui.separator(.{ .style = .{ .foreground = p.divider_card, .background = p.divider_card } }) else ui.spacer(0),
            if (m.home_len > 0) vgap(ui, 4) else ui.spacer(0),
            // The scroll is given the width too, not only the column inside it.
            //
            // Without it the host's paragraphs laid out wider than the card and
            // the overflow was cut, mid-word, with the rest of the sentence
            // continuing on the next line: readable enough to look deliberate
            // and wrong enough to lose a word every line. The markdown renderer
            // never sets `.wrap` on its paragraphs, so the width it is handed is
            // the only thing deciding where a line ends.
            if (m.home_len > 0) ui.scroll(.{ .width = place_info_home_width, .height = placeHomeHeight(placeHome(ui, m)) }, .{
                ui.column(.{ .width = place_info_home_width, .gap = 0 }, .{
                    // With its links live. Passing no options renders them
                    // styled and inert, which is worse than not styling them:
                    // the reader is shown something that looks pressable and
                    // does nothing. They go through `open_url` like every other
                    // link in the app, so the same host checks apply to a
                    // stranger's welcome as to a stranger's note.
                    canvas.markdown.Markdown(Msg).view(ui, placeHome(ui, m), .{ .on_link = AppUi.linkMsg(.open_url) }),
                }),
            }) else ui.spacer(0),
            vgap(ui, 14),
            // Asking, then the answer. The warning is the whole footer while it
            // is up: a confirmation sharing a row with other controls is a
            // confirmation nobody reads.
            if (leaving) ui.paragraph(
                .{ .wrap = true, .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = "Leave this place? It comes off your rail and the notes it was holding are forgotten. The link still works, so you can walk back in.", .scale = join_sub_scale }},
            ) else ui.spacer(0),
            if (leaving) vgap(ui, 12) else ui.spacer(0),
            ui.row(.{ .cross = .center, .gap = 8 }, .{
                if (leaving)
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.place_leave_cancel }, "Cancel")
                else
                    ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.close_place_info }, "Close"),
                ui.spacer(1),
                // Nothing to leave while visiting: a visit is not kept, so there
                // is no list to come off. Home closes the room either way.
                if (!places.g_place_kept)
                    ui.spacer(0)
                else if (leaving)
                    ui.button(.{ .size = .sm, .variant = .destructive, .on_press = Msg.place_leave }, "Leave")
                else
                    ui.button(.{ .size = .sm, .variant = .destructive, .on_press = Msg.place_leave_request }, "Leave"),
            }),
        })),
    }));
}

/// One labelled fact about a place: a quiet name, then the value in mono.
fn placeInfoRow(ui: *AppUi, label: []const u8, value: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0 }, .{
        ui.paragraph(
            .{ .width = 54, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = label, .scale = mono_meta_scale }},
        ),
        ui.paragraph(
            .{ .width = place_info_card_width - 40 - 54, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = value, .monospace = true, .scale = mono_meta_scale }},
        ),
    });
}

/// The header of a room, which is the scope line while you are in one.
///
/// The place's name is the title, the feed it is reading is the meta on the
/// right where the follow feed puts its count of voices, and the verb is one
/// button. The host's own text and the note about privacy are shown only while
/// VISITING: they are the pitch, and a pitch that stays on screen after the
/// answer is a banner in the way of the thing it was selling.
pub fn placeHeader(ui: *AppUi, model: *const Model, m: *const Place) AppUi.Node {
    const p = theme.palette;
    const visiting = !places.g_place_kept;
    const menu_open = model.menu == .place_feed;
    const feed = currentPlaceFeed(m);
    const feed_name = if (feed) |f| (if (f.name_len > 0) f.name() else "") else "";
    return ui.row(.{ .main = .center }, .{ui.column(.{ .width = feed_column_width, .gap = 0 }, .{
        vgap(ui, 11),
        ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = elide(ui, if (m.name_len > 0) m.name() else "A place", header_name_cap), .weight = .bold, .scale = scope_title_scale }},
            ),
            hgap(ui, 8),
            // What THIS place's socket is doing, which the status bar cannot
            // say: it counts the pool, and this relay is deliberately not in
            // it. Silent once connected, because a working connection is not
            // news.
            switch (placeLink()) {
                .connecting => ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint } },
                    &.{.{ .text = "connecting", .monospace = true, .scale = mono_meta_scale }},
                ),
                .unreachable_relay => ui.paragraph(
                    .{ .style = .{ .foreground = p.status_warning } },
                    &.{.{ .text = "cannot reach this place", .monospace = true, .scale = mono_meta_scale }},
                ),
                .refused => ui.paragraph(
                    .{ .style = .{ .foreground = p.status_warning } },
                    &.{.{ .text = "feed closed by its relay", .monospace = true, .scale = mono_meta_scale }},
                ),
                else => ui.spacer(0),
            },
            ui.spacer(1),
            // One feed is a LABEL; several is a switcher. A chevron beside a
            // name that goes nowhere is a promise the room cannot keep, so it
            // appears only when there is somewhere to go.
            if (feed_name.len == 0)
                ui.spacer(0)
            else if (m.feeds_len > 1)
                ui.stack(.{}, .{
                    pressRow(ui, .{
                        .cross = .center,
                        .gap = 5,
                        .on_press = Msg{ .toggle_menu = .place_feed },
                        .style = .{ .quiet_hover = true },
                        .semantics = .{ .role = .button, .label = "Choose feed", .focusable = true },
                    }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_faint_alt } },
                            &.{.{ .text = elide(ui, feed_name, header_feed_cap), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        ui.icon(.{ .width = 10, .height = 10, .style = .{ .foreground = p.text_faint_alt } }, "chevron-down"),
                    }),
                    if (menu_open) placeFeedMenu(ui, m) else ui.spacer(0),
                })
            else
                ui.paragraph(
                    .{ .style = .{ .foreground = p.text_faint_alt } },
                    &.{.{ .text = elide(ui, feed_name, header_feed_cap), .monospace = true, .scale = mono_meta_scale }},
                ),
            if (feed_name.len > 0) hgap(ui, 10) else ui.spacer(0),
            // One control, whatever state you are in: what this place is, who
            // hosts it, where it reads from, and the way out. Leave used to sit
            // right here, a few pixels from Enter, and one press did it.
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.open_place_info }, "Info"),
            // Entering is the only verb the header keeps, because it is the one
            // the reader came for and it should cost one press.
            if (visiting) hgap(ui, 4) else ui.spacer(0),
            if (visiting)
                ui.button(.{ .size = .sm, .variant = .primary, .on_press = Msg.place_enter }, "Enter")
            else
                ui.spacer(0),
            hgap(ui, chrome_inset),
        }),
        if (visiting) vgap(ui, 6) else ui.spacer(0),
        if (visiting) ui.row(.{ .cross = .start, .gap = 0 }, .{
            hgap(ui, chrome_inset),
            ui.paragraph(
                .{ .wrap = true, .grow = 1, .style = .{ .foreground = p.text_faint } },
                &.{.{ .text = "Just visiting. Entering keeps this place on your rail, and nobody else can see which places you have entered.", .scale = mono_hint_scale }},
            ),
            hgap(ui, chrome_inset),
        }) else ui.spacer(0),
        vgap(ui, 9),
        ui.separator(.{ .width = feed_column_width, .style = .{ .foreground = p.divider_chrome, .background = p.divider_chrome } }),
    })});
}

pub fn scopeHeader(ui: *AppUi, model: *const Model) AppUi.Node {
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
                pressRow(ui, .{
                    .cross = .center,
                    .gap = 7,
                    .on_press = Msg{ .toggle_menu = .scope },
                    .style = .{ .quiet_hover = true },
                    .semantics = .{ .role = .button, .label = "Choose feed", .focusable = true },
                }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_primary } },
                        &.{.{ .text = model.scope_name(), .weight = .bold, .scale = scope_title_scale }},
                    ),
                    ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.text_muted } }, "chevron-down"),
                }),
                if (model.menu == .scope) scopeMenu(ui, model.scope_name()) else ui.spacer(0),
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
pub fn statusBar(ui: *AppUi, model: *const Model) AppUi.Node {
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
fn scopeMenu(ui: *AppUi, scope: []const u8) AppUi.Node {
    // One feed is a LABEL, several is a switcher: the same rule the place header
    // follows. Until the reader has followed somebody there is only the pack,
    // and a menu offering a feed with nobody in it is a promise Home cannot
    // keep.
    if (!homeScopeSwitchable()) {
        const rows = ui.arena.alloc(AppUi.Node, 2) catch return ui.spacer(0);
        rows[0] = menuRow(ui, scope, "check", null, .close_menu);
        // Why there is nothing to choose, and what would change that, so the
        // menu is not a chevron that opens onto the word already on screen. One
        // line, because a wrapped paragraph is not counted in the surface's
        // height and the second line would hang out of the bottom of it.
        rows[1] = ui.row(.{ .cross = .center, .gap = 0 }, .{
            hgap(ui, 9),
            vgap(ui, 25),
            ui.paragraph(
                .{ .style = .{ .foreground = theme.palette.text_label } },
                &.{.{ .text = "Follow someone to add your Following feed.", .scale = mono_hint_scale }},
            ),
        });
        return menuSurfacePlaced(ui, 280, .below, .start, rows);
    }
    const rows = ui.arena.alloc(AppUi.Node, 2) catch return ui.spacer(0);
    const on_pack = homeReadsPack();
    // The pack first, because it is where a new key starts and the row they are
    // looking for is the one they are leaving.
    rows[0] = menuRow(
        ui,
        "Starter pack",
        if (on_pack) "check" else null,
        "hand-picked",
        Msg{ .choose_home_scope = 0 },
    );
    rows[1] = menuRow(
        ui,
        "Following",
        if (on_pack) null else "check",
        if (followTotalOwned() == 1) "1 account" else ui.fmt("{d} accounts", .{followTotalOwned()}),
        Msg{ .choose_home_scope = 1 },
    );
    // The scope line sits at the top of the window, so its menu drops down.
    return menuSurfacePlaced(ui, 240, .below, .start, rows);
}

/// The place's feeds, with the one being read checked.
///
/// Hallway communities routinely list several (its own default document has
/// five), and a room that showed one was not a smaller feature, it was most of
/// the community missing. The menu is the scope menu's shape on purpose: this
/// IS the scope line while you are in a place, so choosing a feed should look
/// like choosing a feed.
fn placeFeedMenu(ui: *AppUi, m: *const Place) AppUi.Node {
    const n = m.feeds_len;
    const rows = ui.arena.alloc(AppUi.Node, n) catch return ui.spacer(0);
    const open_index = @min(places.g_place_feed, if (n == 0) 0 else n - 1);
    for (rows, 0..) |*row, i| {
        const f = &m.feeds[i];
        // A feed with no name of its own is its relay's host, the same
        // substitution the header and the parser already make.
        const label = if (f.name_len > 0) f.name() else relayHost(f.relay());
        const glyph: ?[]const u8 = if (i == open_index) "check" else null;
        row.* = menuRow(ui, label, glyph, null, Msg{ .place_feed = @intCast(i) });
    }
    return menuSurfacePlaced(ui, 220, .below, .start, rows);
}

/// A scope name as it reads mid-sentence.
///
/// Only the app's OWN two names are lowered. It used to return "starter pack"
/// for anything that was not "Following", which was safe while those were the
/// only two scopes there were, and became a plain lie the moment a place could
/// be one: the status bar said "caught up, starter pack" under a header naming
/// somebody else's room. A place's feed name is a stranger's proper noun and is
/// left exactly as they wrote it.
pub fn lowerScope(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "Following")) return "following";
    if (std.mem.eql(u8, scope, "Starter pack")) return "starter pack";
    return scope;
}

pub fn setPlaceLogoIdForTest(id: u64) void {
    g_place_logo_id = id;
}
/// Whether the mark on screen belongs to the room on screen, for the test.
pub fn placeLogoShownForTest() bool {
    return g_place_logo_state == .loaded and g_place_logo_id != 0;
}
/// A mark loaded and on screen for a given place, the way a finished fetch
/// leaves it, so a test can walk out of that room and see what stays behind.
pub fn setPlaceLogoLoadedForTest(id: u64, pubkey: [32]u8, ident: []const u8) void {
    g_place_logo_id = id;
    g_place_logo_for = pubkey;
    g_place_logo_for_ident_len = @intCast(copyBounded(&g_place_logo_for_ident_buf, ident));
    g_place_logo_state = .loaded;
}

pub fn scanPlaceLogoForTest(fx: *Effects, model: *const Model) void {
    scanPlaceLogo(fx, model);
}

/// A fetch in flight, started by a given place.
pub fn setPlaceLogoAskedForTest(pubkey: [32]u8, ident: []const u8) void {
    g_place_logo_asked_for = pubkey;
    g_place_logo_asked_ident_len = @intCast(copyBounded(&g_place_logo_asked_ident_buf, ident));
    g_place_logo_state = .fetching;
}

pub fn placeLogoStateNameForTest() []const u8 {
    return @tagName(g_place_logo_state);
}

/// Hands the logo pipeline a fetched body, the way the effect loop does.
pub fn deliverPlaceLogoBodyForTest(fx: *Effects, body: []const u8) void {
    handlePlaceLogoFetched(fx, .{
        .key = place_logo_fetch_key,
        .outcome = .ok,
        .status = 200,
        .body = body,
    });
}

pub fn visibleLenForTest(line: []const u8) usize {
    return visibleLen(line);
}

pub fn placeHomeHeightForTest(text: []const u8) f32 {
    return placeHomeHeight(text);
}

pub fn stripEmptyImagesForTest(arena: std.mem.Allocator, src: []const u8) []const u8 {
    return stripEmptyImages(arena, src);
}

pub fn lowerScopeForTest(scope: []const u8) []const u8 {
    return lowerScope(scope);
}

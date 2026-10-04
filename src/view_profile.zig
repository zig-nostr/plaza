//! The profile screen and its banner.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const prefs = @import("prefs.zig");
const profile_cache = @import("profile_cache.zig");
const profile_notes = @import("profile_notes.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Download = main.Download;
const Effects = main.Effects;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const acquireImageId = main.acquireImageId;
const activePubkey = main.activePubkey;
const backControl = main.backControl;
const backLabel = main.backLabel;
const banner_target_px = main.banner_target_px;
const bookmarkCount = main.bookmarkCount;
const decodeAndRegister = main.decodeAndRegister;
const elide = main.elide;
const feed_column_width = main.feed_column_width;
const feed_row_chrome = main.feed_row_chrome;
const fetchSlice = main.fetchSlice;
const followBlockedReason = main.followBlockedReason;
const followsMe = main.followsMe;
const hgap = main.hgap;
const hostOf = main.hostOf;
const identityInk = main.identityInk;
const isFollowedByMe = main.isFollowedByMe;
const isMuted = main.isMuted;
const loadCachedImage = main.loadCachedImage;
const max_image_bytes = main.max_image_bytes;
const mediaUrl = main.mediaUrl;
const menu_scale = main.menu_scale;
const meta_scale = main.meta_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const muteBlockedReason = main.muteBlockedReason;
const noteCard = main.noteCard;
const noteRowEstimate = main.noteRowEstimate;
const ownListsAdvice = main.ownListsAdvice;
const ownListsProgress = main.ownListsProgress;
const ownListsRead = main.ownListsRead;
const personAbout = main.personAbout;
const personAvatar = main.personAvatar;
const personBanner = main.personBanner;
const personCheck = main.personCheck;
const personFollowingCount = main.personFollowingCount;
const personIsNamed = main.personIsNamed;
const personLud16 = main.personLud16;
const personName = main.personName;
const personNpubShort = main.personNpubShort;
const personWebsite = main.personWebsite;
const profileEndReached = main.profileEndReached;
const profile_avatar_lift = main.profile_avatar_lift;
const profile_avatar_size = main.profile_avatar_size;
const profile_band_name_max = main.profile_band_name_max;
const profile_banner_height = main.profile_banner_height;
const profile_bio_line_height = main.profile_bio_line_height;
const profile_card_chrome = main.profile_card_chrome;
const profile_handle_max = main.profile_handle_max;
const profile_links_height = main.profile_links_height;
const profile_name_max = main.profile_name_max;
const profile_name_scale = main.profile_name_scale;
const profile_notes_max = main.profile_notes_max;
const proxyRefusedHost = main.proxyRefusedHost;
const proxyRefusesHost = main.proxyRefusesHost;
const quiet_row_extent = main.quiet_row_extent;
const recordProfileVisible = main.recordProfileVisible;
const rememberHostRefusal = main.rememberHostRefusal;
const rowExtentFromTable = main.rowExtentFromTable;
const row_pad_side = main.row_pad_side;
const storeCachedImage = main.storeCachedImage;
const verifiedNip05 = main.verifiedNip05;
const vgap = main.vgap;
const window_height = main.window_height;

/// SUPERSEDED, kept for the argument it lost.
///
/// The banner had a reserved id, on the reasoning that one non-scrolling
/// consumer does not exercise an allocator. That was true, and it stopped being
/// the point: pictures did cross the pools, so the allocator exists now, and a
/// reserved id would be the one slot it could not reach.
///
/// The old note:
///
/// The profile banner's own id, taken out of the avatar pool rather than
/// borrowed from either LRU.
///
/// The block above argues for ONE allocator over all sixteen slots, and that is
/// still the right end state. It is not this change. A banner is one image on a
/// screen that occludes the feed: it never scrolls, never competes with a second
/// banner, and is overwritten in place when the reader walks to another person.
/// A reserved id therefore needs no eviction pass at all, and cannot take a
/// picture the feed is using in ANY navigation order, which is exactly what
/// borrowing from the media LRU could do. Unifying here would still be writing
/// the allocator against imagined callers; a single non-scrolling consumer does
/// not exercise one.
///
/// The cost is one avatar id, and it is not observable: ids are lent only to the
/// visible window, and a window this size holds a handful of rows, so the tenth id
/// only ever lengthened the LRU tail. A reclaimed avatar returns from the disk
/// cache, not the network.
/// Which registry id the banner is holding, or 0 for none. A variable now,
/// because the banner takes its slot from the same pool as everything else.
pub var g_banner_image_id: u64 = 0;
/// The tick the banner was last on screen.
pub var g_banner_seen: u64 = 0;
/// The band, drawn from the registered image. `cover` so a wide picture fills
/// the strip rather than letterboxing inside it.
fn bannerImage(ui: *AppUi) AppUi.Node {
    var node = ui.image(.{
        .image = g_banner_image_id,
        .height = profile_banner_height,
        .grow = 1,
        .semantics = .{ .label = "Profile banner" },
    });
    node.widget.image_fit = .cover;
    return node;
}

/// The banner currently registered, and for whom. One at a time, because one
/// screen shows one.
var g_banner_for: ?[32]u8 = null;
/// Who the in-flight fetch was started for, which is not always who is on
/// screen by the time it lands.
var g_banner_asked_for: ?[32]u8 = null;
pub var g_banner_state: enum { idle, fetching, loaded, failed } = .idle;
var g_banner_url_buf: [1024]u8 = undefined;
var g_banner_url_len: u16 = 0;
/// The host the banner actually lives on, kept for the same reason a picture
/// slot keeps one: while the proxy is in the way, the fetch URL's host is the
/// proxy's, and a refusal has to be written down under the real one.
var g_banner_host_buf: [96]u8 = undefined;
var g_banner_host_len: u8 = 0;
/// Ask the banner's own host rather than the proxy, for the same reason a face
/// does. Cleared whenever the banner is started for somebody else.
var g_banner_direct: bool = false;

fn bannerUrl() []const u8 {
    return g_banner_url_buf[0..g_banner_url_len];
}

/// Whether a banner is registered for `pubkey` right now.
fn bannerReady(pubkey: [32]u8) bool {
    const who = g_banner_for orelse return false;
    return g_banner_state == .loaded and std.mem.eql(u8, &who, &pubkey);
}

/// Asks for the open profile's banner, once per person.
pub fn scanBannerFetch(fx: *Effects, model: *const Model) void {
    const pubkey = model.viewing_profile orelse {
        // Left the screen: the next person starts clean, and the slot goes back
        // to the pool rather than sitting on a picture nobody can see. The feed
        // underneath is exactly what wants it.
        if (g_banner_image_id != 0) {
            _ = fx.unregisterImage(g_banner_image_id);
            g_banner_image_id = 0;
        }
        g_banner_for = null;
        g_banner_state = .idle;
        return;
    };
    // On screen this pass, so the allocator will not take it out from under the
    // reader while they are looking at it.
    g_banner_seen = profile_cache.g_image_clock;
    if (!prefs.g_media_previews) return;
    const changed = if (g_banner_for) |who| !std.mem.eql(u8, &who, &pubkey) else true;
    if (changed) {
        g_banner_for = pubkey;
        g_banner_state = .idle;
        g_banner_url_len = 0;
        // A different person's banner is a different host, so it goes through
        // the proxy first like any other.
        g_banner_direct = false;
    }
    if (g_banner_state != .idle) return;

    const raw = personBanner(pubkey);
    if (raw.len == 0) return;
    var url_buf: [1024]u8 = undefined;
    const url = if (g_banner_direct or proxyRefusesHost(raw)) raw else mediaUrl(&url_buf, raw, banner_target_px, .inside);
    const bhost = hostOf(raw);
    const bn = @min(bhost.len, g_banner_host_buf.len);
    @memcpy(g_banner_host_buf[0..bn], bhost[0..bn]);
    g_banner_host_len = @intCast(bn);
    const n = @min(url.len, g_banner_url_buf.len);
    @memcpy(g_banner_url_buf[0..n], url[0..n]);
    g_banner_url_len = @intCast(n);

    // A slot from the shared pool, the same one faces and pictures come from.
    // The banner marks itself on screen every pass a profile is open, so the
    // allocator will not take it back underneath the reader.
    if (g_banner_image_id == 0) {
        g_banner_image_id = acquireImageId(fx) orelse return;
    }
    if (loadCachedImage(fx, g_banner_image_id, bannerUrl(), banner_target_px)) |_| {
        g_banner_state = .loaded;
        return;
    }
    g_banner_state = .fetching;
    g_banner_asked_for = pubkey;
    g_banner_down.release();
    fetchSlice(fx, banner_fetch_key, bannerUrl(), 0, Effects.responseMsg(.banner_fetched));
}

/// A banner too big for one response body. The widest of the three, drawn at
/// 660x132, so the least likely of them to arrive in one piece.
var g_banner_down: Download = .{};

/// Deliberately not 4000: that is `link_fetch_key_base + 0`, and the runtime
/// rejects a second fetch under a key already in flight, so a banner and the
/// first link preview would refuse each other.
const banner_fetch_key: u64 = 5000;

pub fn handleBannerFetched(fx: *Effects, response: native_sdk.EffectResponse) void {
    if (response.key != banner_fetch_key) return;
    // WHOSE banner this is. A fetch takes as long as it takes, and the reader
    // may have walked to somebody else meanwhile: without this the bytes paint
    // over the person now on screen AND are cached under their URL, so the wrong
    // face persists across restarts.
    const asked_for = g_banner_asked_for orelse return;
    const showing = g_banner_for orelse return;
    if (!std.mem.eql(u8, &asked_for, &showing)) {
        g_banner_down.release();
        g_banner_state = .idle;
        return;
    }
    // Every effect slot was busy: ask again next tick.
    if (response.outcome == .rejected) {
        g_banner_down.release();
        g_banner_state = .idle;
        return;
    }
    // A slice of a banner bigger than one body.
    if (response.outcome == .ok and response.status == 206 and !response.truncated and response.body.len > 0) {
        const outcome = g_banner_down.append(response.body) orelse {
            g_banner_down.release();
            g_banner_state = .failed;
            return;
        };
        if (outcome == .want_more) {
            fetchSlice(fx, banner_fetch_key, bannerUrl(), g_banner_down.len, Effects.responseMsg(.banner_fetched));
            return;
        }
        const whole = g_banner_down.bytes() orelse response.body;
        finishBanner(fx, whole);
        g_banner_down.release();
        return;
    }
    // Anything but a clean, whole, OK image body leaves the flat band, which is
    // a perfectly good banner.
    if (response.outcome != .ok or response.status != 200 or response.truncated or
        response.body.len == 0 or response.body.len > max_image_bytes)
    {
        g_banner_down.release();
        // The proxy refusing the HOST, not the picture. Once, and only while
        // the proxy is what was used.
        if (prefs.g_media_direct_fallback and prefs.g_media_proxy_on and !g_banner_direct and
            proxyRefusedHost(response.outcome, response.status))
        {
            rememberHostRefusal(g_banner_host_buf[0..g_banner_host_len]);
            g_banner_direct = true;
            g_banner_state = .idle;
            return;
        }
        g_banner_state = .failed;
        return;
    }
    g_banner_down.release();
    finishBanner(fx, response.body);
}

/// Decodes a complete banner into the slot it holds.
fn finishBanner(fx: *Effects, bytes: []const u8) void {
    if (decodeAndRegister(fx, g_banner_image_id, bytes, banner_target_px)) |_| {
        g_banner_state = .loaded;
        storeCachedImage(bannerUrl(), bytes);
    } else {
        g_banner_state = .failed;
    }
}
/// The 44px band above a person: Back, and who this is.
fn profileHeaderBand(ui: *AppUi, model: *const Model, pubkey: [32]u8) AppUi.Node {
    return levelBand(ui, model, elide(ui, personName(ui, pubkey), profile_band_name_max));
}

/// The strip across the top of a stacked list level: Back, naming where it
/// lands, and what this level is. Every level that sits over the feed owes the
/// reader a way off it, and a topic and the bookmark list went without one
/// because only a person's page had this band.
fn levelBand(ui: *AppUi, model: *const Model, title: []const u8) AppUi.Node {
    const p = theme.palette;
    const back_label = backLabel(model, ui.arena);
    return ui.column(.{}, .{
        ui.row(.{ .cross = .center, .gap = 10, .padding = 12 }, .{
            backControl(ui, back_label, Msg.close_thread),
            ui.spacer(1),
            ui.paragraph(
                .{ .style = .{ .foreground = p.text_primary } },
                &.{.{ .text = title, .weight = .medium, .scale = menu_scale }},
            ),
            ui.spacer(1),
            hgap(ui, 48),
        }),
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
    });
}

/// How tall the person card is. Measured, not guessed: a bio wraps and a links
/// row may be absent, and a virtual list that mis-measures its first row scrolls
/// to the wrong place for every row after it.
fn profileCardExtent(rows: *const ProfileRows) f32 {
    var h: f32 = profile_banner_height + profile_card_chrome;
    const about = personAbout(rows.subject());
    if (about.len > 0) {
        // Roughly 62 characters to a line at the body scale, over the 660 column.
        const lines: f32 = @floatFromInt(1 + about.len / 62);
        h += lines * profile_bio_line_height + 9;
    }
    if (personWebsite(rows.subject()).len > 0 or personLud16(rows.subject()).len > 0) h += profile_links_height;
    return h;
}

/// Whether this page belongs to the reader looking at it.
///
/// The profile was written for a stranger, because for a long time a stranger was
/// the only person it could be about: the way onto it was pressing somebody's face
/// in the feed. Now the rail's seat opens the reader's own, so every sentence that
/// says "they" has to say "you" here, and the first reader through that door is a
/// brand new account whose page is entirely empty states.
fn isMe(pubkey: [32]u8) bool {
    const me = activePubkey() orelse return false;
    return std.mem.eql(u8, &me, &pubkey);
}

/// The person: their banner, their face, what they say about themselves, and
/// what this app can honestly tell the reader about them.
fn profileCard(ui: *AppUi, model: *const Model, pubkey: [32]u8) AppUi.Node {
    const p = theme.palette;
    const about = personAbout(pubkey);
    const website = personWebsite(pubkey);
    const lud16 = personLud16(pubkey);
    const is_me = isMe(pubkey);
    const named = personIsNamed(pubkey);
    const follows_me = followsMe(pubkey);
    // Nothing to show and no room to leave for it: with neither the npub nor the
    // follows-you note, the row measures zero and its 5px lead-in would sit under
    // the name as dead space. That is the freshly minted key's own page.
    // Their NIP-05, once it has actually been checked. It goes ahead of the npub
    // because it is the identifier a person chose and can prove, where the npub
    // is the one the maths chose.
    const handle = verifiedNip05(pubkey);

    return ui.column(.{ .gap = 0 }, .{
        // The banner, with the face riding up over its lower edge. There is no
        // negative margin on this engine, so the two are STACKED: one child is
        // the banner plus the disc's overhang, the other is that same height
        // made of a gap and then the disc. Equal heights, so the stack is
        // exactly as tall as the band plus what hangs below it, and the name
        // row after it starts clear of both.
        ui.stack(.{}, .{
            ui.column(.{ .gap = 0 }, .{
                // A flat band until an image is afforded: an empty box that
                // holds its height beats a jump when one arrives.
                if (bannerReady(pubkey))
                    bannerImage(ui)
                else
                    ui.el(.panel, .{
                        .height = profile_banner_height,
                        .padding = 0.01,
                        .style = .{ .background = p.surface_stripe_a, .border = p.surface_stripe_a, .radius = 0, .stroke_width = 0 },
                    }, .{}),
                vgap(ui, profile_avatar_size - profile_avatar_lift),
            }),
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, profile_banner_height - profile_avatar_lift),
                // Bottom-aligned, not top. The disc is the tallest thing here
                // and it deliberately overhangs the banner, so aligning the
                // cluster to the TOP of this row put it ON the band, over the
                // subject's own picture. Against the bottom it lands in the
                // overhang, clear of the banner and level with the face.
                ui.row(.{ .cross = .end, .gap = 0 }, .{
                    hgap(ui, 20),
                    personAvatar(ui, pubkey, profile_avatar_size),
                    ui.spacer(1),
                    profileActions(ui, model, pubkey, is_me),
                    hgap(ui, 20),
                }),
            }),
        }),
        ui.row(.{ .gap = 0 }, .{
            hgap(ui, 20),
            ui.column(.{ .gap = 0, .grow = 1 }, .{
                vgap(ui, 8),
                ui.row(.{ .cross = .center, .gap = 7 }, .{
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_primary } },
                        &.{.{ .text = elide(ui, personName(ui, pubkey), profile_name_max), .weight = .bold, .scale = profile_name_scale }},
                    ),
                    personCheck(ui, pubkey),
                }),
                // The npub is skipped when the name line IS that string. A key
                // with no kind:0 has no name, so `personName` hands back the
                // short npub, and printing it again directly underneath says
                // nothing twice. The reader most likely to see it is the one
                // whose key was minted a minute ago and has not named it yet,
                // which is the same reader the rail's seat now opens this page
                // for.
                //
                // `.gap = 0` with the 8 spelled out, NOT a gap of 8 with a
                // zero-width spacer standing in for the npub. A row gap is
                // charged for every flow child whatever its extent, so the
                // spacer would still push "follows you" 8px past the left rule
                // that the name, bio, links and counts all share. `handleLine`
                // documents this exact trap and I walked into it anyway.
                // One fact per line, in the order they are worth: the name,
                // the address that was verified, the key itself, then where to
                // pay them. They used to share a row, which read as one long
                // strip of identifiers and put the npub, the thing most likely
                // to be copied, in the middle of it.
                if (handle.len > 0) vgap(ui, 5) else ui.spacer(0),
                if (handle.len > 0)
                    ui.paragraph(
                        .{ .style = .{ .foreground = identityInk() } },
                        &.{.{ .text = elide(ui, handle, profile_handle_max), .scale = meta_scale }},
                    )
                else
                    ui.spacer(0),
                if (named) vgap(ui, 4) else ui.spacer(0),
                if (named)
                    ui.row(.{ .cross = .center, .gap = 8 }, .{
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = personNpubShort(ui, pubkey), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        // Kept beside the key rather than given a line of its
                        // own: it is a fact about the two of you, not another
                        // way to address them.
                        if (follows_me)
                            ui.paragraph(.{ .style = .{ .foreground = p.text_faint } }, &.{.{ .text = "follows you", .scale = meta_scale }})
                        else
                            ui.spacer(0),
                    })
                else
                    ui.spacer(0),
                // A key with no name of its own shows no npub either, because
                // the name line already IS that string. The badge still has to
                // appear: hanging it off the npub's branch made it vanish for
                // exactly the readers whose page has least on it, and a test
                // written for the old layout caught that.
                if (follows_me and !named) vgap(ui, 4) else ui.spacer(0),
                if (follows_me and !named)
                    ui.paragraph(.{ .style = .{ .foreground = p.text_faint } }, &.{.{ .text = "follows you", .scale = meta_scale }})
                else
                    ui.spacer(0),
                if (lud16.len > 0) vgap(ui, 4) else ui.spacer(0),
                if (lud16.len > 0)
                    ui.paragraph(
                        .{ .style = .{ .foreground = p.text_muted_alt } },
                        &.{.{ .text = elide(ui, lud16, profile_handle_max), .monospace = true, .scale = mono_hint_scale }},
                    )
                else
                    ui.spacer(0),
                if (about.len > 0) vgap(ui, 9) else ui.spacer(0),
                if (about.len > 0)
                    ui.paragraph(
                        .{ .size = .sm, .wrap = true, .style = .{ .foreground = p.text_body_soft } },
                        &.{.{ .text = about }},
                    )
                else
                    ui.spacer(0),
                if (website.len > 0) profileLinks(ui, website) else ui.spacer(0),
                vgap(ui, 9),
                profileCounts(ui, pubkey, is_me),
                if (!is_me) ownListsHint(ui) else ui.spacer(0),
                vgap(ui, 14),
                profileTabs(ui, model),
            }),
            hgap(ui, 20),
        }),
    });
}

/// The line under a profile's counts when Follow or Mute is off because the
/// reader's own list has not been read. It says which list, how far the read got
/// and, once the wait ran out, offers to ask again: a greyed button with a
/// sentence that never changes is a dead end.
fn ownListsHint(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const follow_off = followBlockedReason() != null;
    const mute_off = muteBlockedReason() != null;
    if (!follow_off and !mute_off) return ui.spacer(0);
    const state = ownListsRead();
    const both = follow_off and mute_off;
    const lists = if (both) "follow and mute lists" else if (follow_off) "follow list" else "mute list";
    const what = if (both) "Following and muting are" else if (follow_off) "Following is" else "Muting is";
    const text = switch (state) {
        .reading => ui.fmt("Still reading your own {s}. {s} off until {s}, because writing before then would replace {s}.", .{
            lists, what, if (both) "they arrive" else "it arrives", if (both) "them" else "it",
        }),
        .incomplete => ui.fmt("{s} Plaza could not finish reading your {s}. {s} off rather than replace a list it has not seen.{s}", .{
            ownListsProgress(ui), lists, what, ownListsAdvice(),
        }),
        // Both controls are live here (the press asks first), so there is
        // nothing off to explain.
        .none_found => return ui.spacer(0),
    };
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 7),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = text, .scale = mono_hint_scale }},
        ),
        if (state == .incomplete)
            ui.column(.{ .gap = 0 }, .{
                vgap(ui, 6),
                ui.row(.{ .gap = 0 }, .{ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg.retry_own_lists }, "Try again")}),
            })
        else
            ui.spacer(0),
    });
}

/// The action cluster: zap (inert), the overflow menu, and Follow.
fn profileActions(ui: *AppUi, model: *const Model, pubkey: [32]u8, is_me: bool) AppUi.Node {
    _ = model;
    if (is_me) {
        const p = theme.palette;
        // Your own page. Editing lives in Settings, and a second door to it here
        // would be a second thing to keep true.
        return ui.paragraph(.{ .style = .{ .foreground = p.text_faint } }, &.{.{ .text = "This is you", .scale = meta_scale }});
    }
    const following = isFollowedByMe(pubkey);
    const muted = isMuted(pubkey);
    return ui.row(.{ .cross = .center, .gap = 8 }, .{
        // Muting is quieter than following, in the layout as well as in what it
        // does: a ghost button beside the primary one, and it says the state it
        // is in rather than the verb it performs when that state is unusual.
        if (muteBlockedReason() != null)
            ui.button(.{ .size = .sm, .variant = .ghost, .disabled = true, .on_press = Msg{ .mute_person = 1 } }, "Mute")
        else if (muted)
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .mute_person = 2 } }, "Muted")
        else
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .mute_person = 1 } }, "Mute"),
        // Disabled rather than absent while the app is still reading the
        // reader's own list: a control that vanishes is a control they will
        // wonder about, and one that silently no-ops is worse. The sentence
        // explaining it sits under the counts, where there is room for it.
        if (followBlockedReason() != null)
            ui.button(.{ .size = .sm, .variant = .primary, .disabled = true, .on_press = Msg{ .follow_person = 1 } }, "Follow")
        else if (following)
            ui.button(.{ .size = .sm, .variant = .ghost, .on_press = Msg{ .follow_person = 2 } }, "Following")
        else
            ui.button(.{ .size = .sm, .variant = .primary, .on_press = Msg{ .follow_person = 1 } }, "Follow"),
    });
}

/// Where they point people, when they point anywhere.
/// The website line. The lightning address used to share this row and now sits
/// with the other ways to address someone, directly under the key.
///
/// Shortened rather than bounded: a stranger's `website` is printed whole, up to
/// the 128 bytes of the buffer that holds it, and the profile page is the one
/// screen that never picks up the fixed reading column, so nothing above this
/// leaf would have stopped it at the window's edge.
fn profileLinks(ui: *AppUi, website: []const u8) AppUi.Node {
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 8),
        ui.row(.{ .cross = .center, .gap = 14 }, .{
            ui.paragraph(
                .{ .style = .{ .foreground = identityInk() } },
                &.{.{ .text = elide(ui, website, profile_handle_max), .scale = meta_scale }},
            ),
            ui.spacer(1),
        }),
    });
}

/// What this app can honestly count.
///
/// Following is theirs to state: it is the length of their own contact list.
/// FOLLOWERS is not. Nothing in a local store can know who follows somebody,
/// and the honest options are an indexer's number or none. This app does not
/// state numbers it cannot verify, so it says nothing rather than a figure the
/// reader would reasonably believe.
fn profileCounts(ui: *AppUi, pubkey: [32]u8, is_me: bool) AppUi.Node {
    const p = theme.palette;
    const following = personFollowingCount(pubkey);
    return ui.row(.{ .cross = .center, .gap = 16 }, .{
        if (following) |n|
            ui.row(.{ .cross = .center, .gap = 5 }, .{
                ui.paragraph(.{ .style = .{ .foreground = p.text_body_strong } }, &.{.{ .text = ui.fmt("{d}", .{n}), .weight = .medium, .scale = menu_scale }}),
                ui.paragraph(.{ .style = .{ .foreground = p.text_muted_alt } }, &.{.{ .text = "following", .scale = menu_scale }}),
            })
        else
            ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{
                .text = if (is_me) "Your follow list has not arrived yet" else "Their follow list has not arrived yet",
                .scale = mono_hint_scale,
            }}),
        ui.spacer(1),
    });
}

/// Notes, or replies. Two tabs that mean exactly what they say.
fn profileTabs(ui: *AppUi, model: *const Model) AppUi.Node {
    return ui.row(.{ .cross = .center, .gap = 6 }, .{
        profileTab(ui, "Notes", model.profile_tab == .notes, Msg{ .profile_tab = 0 }),
        profileTab(ui, "Replies", model.profile_tab == .replies, Msg{ .profile_tab = 1 }),
        ui.spacer(1),
    });
}

pub fn profileTab(ui: *AppUi, label: []const u8, active: bool, msg: Msg) AppUi.Node {
    return profileTabFocused(ui, label, active, msg, false);
}

/// The same tab, optionally taking the keyboard when it mounts. The
/// notifications sheet has no way-out control of its own, so its first tab is
/// what gives Escape a focused widget to resolve from; switching tabs is the
/// worst an accidental Return can do from there.
pub fn profileTabFocused(ui: *AppUi, label: []const u8, active: bool, msg: Msg, focus: bool) AppUi.Node {
    const p = theme.palette;
    return ui.el(.list_item, .{
        .padding = 0.01,
        .height = 26,
        .cross = .center,
        .autofocus = focus,
        .on_press = msg,
        .style = .{
            .background = if (active) p.surface_settings_card else p.surface_window,
            .border = if (active) p.border_chip else p.surface_window,
            .radius = 8,
            .stroke_width = 1,
        },
        .semantics = .{ .role = .tab, .label = label, .focusable = true },
    }, .{
        hgap(ui, 11),
        ui.paragraph(
            .{ .style = .{ .foreground = if (active) p.text_primary else p.text_muted_alt } },
            // One weight for both. The active tab already has its own fill,
            // border and text colour, and changing the weight as well moved the
            // glyph metrics, so the two labels sat on different baselines inside
            // boxes that were centred correctly. The tabs looked misaligned and
            // the row was never the problem.
            &.{.{ .text = label, .scale = menu_scale }},
        ),
        hgap(ui, 11),
    });
}

/// The quiet line under an empty tab.
fn profileEmptyRow(ui: *AppUi, rows: *const ProfileRows) AppUi.Node {
    const p = theme.palette;
    // A key minted a minute ago has written nothing, so this is the ONE screen a
    // new reader is most likely to see first, and "Nothing they have written" is
    // the app talking about them behind their back on their own page.
    const mine = isMe(rows.subject());
    // A tag and the bookmark list are about no person, so the sentences below
    // about what somebody "has written" are not theirs to say.
    const text: []const u8 = if (rows.header == .topic)
        if (rows.loading) "Looking for notes with this tag…" else "No notes with this tag yet."
    else if (rows.header == .bookmarks)
        // Saved but never fetched is not the same as nothing saved, and the
        // card above already says those are not listed.
        if (bookmarkCount() == 0) "Nothing saved here yet." else "None of your saved notes are on this machine yet."
    else if (rows.loading)
        if (mine) "Looking for what you have written…" else "Looking for what they have written…"
    else if (rows.model.profile_tab == .replies)
        if (mine) "Nothing you have written at anyone is here yet." else "Nothing they have written at anyone is here yet."
    else if (mine) "Nothing you have written is here yet." else "Nothing they have written is here yet.";
    return ui.row(.{ .cross = .center, .gap = 0, .height = quiet_row_extent }, .{
        hgap(ui, 20),
        ui.paragraph(.{ .wrap = true, .style = .{ .foreground = p.text_dim } }, &.{.{ .text = text, .scale = mono_hint_scale }}),
        hgap(ui, 20),
    });
}

/// A profile level's key, in the same space as a thread's so the two never
/// collide when they sit in one stack. The top bit marks it a person.
pub fn profileLevelKey(level: usize, pubkey: [32]u8) u64 {
    const hi = @as(u64, level) << 59;
    const lo = std.mem.readInt(u64, pubkey[0..8], .big) & ((@as(u64, 1) << 58) - 1);
    return hi | lo | (@as(u64, 1) << 58);
}

/// What a profile level draws: the person, then what they have written.
///
/// One virtual list, with the whole profile header as row 0. The header is tall
/// and variable (a bio wraps, a links row may be absent) and it scrolls away
/// with the notes, which is what the design asks for and what a column above a
/// list cannot do. This is the same heterogeneous-row shape the thread already
/// uses for its ancestors.
/// What a stacked list level is showing. One value rather than a pubkey plus an
/// optional topic plus a flag, because those three encode a choice of one and
/// nothing stops two of them being set at once.
const LevelHeader = union(enum) {
    person: [32]u8,
    topic: []const u8,
    bookmarks,
};

pub fn profilePanel(
    ui: *AppUi,
    model: *const Model,
    header: LevelHeader,
    notes: []const Note,
    loading: bool,
    level_key: u64,
    level: usize,
    occluded: bool,
) AppUi.Node {
    const rows_ctx = ui.arena.create(ProfileRows) catch return ui.column(.{}, .{});
    // From the ARENA, never the stack. The SDK RETAINS `extent_context` and calls
    // the estimator again in a post-layout measure pass, long after this function
    // has returned: a slice of a local here is read back out of a reclaimed frame,
    // and the index it yields then indexes `notes` with whatever layout left on
    // that word. The arena survives to the top of the next build, which is
    // exactly as long as the retained table needs it.
    const indices = ui.arena.alloc(usize, notes.len) catch return ui.column(.{}, .{});
    // An occluded level still reports its REAL row count: the retained list keeps
    // its scroll offset from the count and the extents, so claiming two rows here
    // would collapse the person's scroll and Back would land at the top.
    // A topic's rows were already chosen by the store query, so every note
    // handed in belongs. A person's are filtered here because `thread_notes` is
    // one buffer shared with the thread screen.
    const shown = switch (header) {
        .person => |pk| model.profileNotesFor(indices, pk),
        // A topic's rows and a bookmark's were already chosen, by the store
        // query and by the list itself, so every note handed in belongs. A
        // person's are filtered here because `thread_notes` is one buffer
        // shared with the thread screen.
        else => blk: {
            var n: usize = 0;
            while (n < notes.len and n < indices.len) : (n += 1) indices[n] = n;
            break :blk indices[0..n];
        },
    };
    rows_ctx.* = .{
        .model = model,
        .header = header,
        .notes = notes,
        .shown = shown,
        .loading = loading,
        .footer = switch (header) {
            .person => |pk| profileFooter(model, pk, shown.len),
            else => .none,
        },
    };
    const table = &main.g_profile_extents[@min(level, main.g_profile_extents.len - 1)];
    table.reset();
    if (!occluded) {
        var row: usize = 0;
        const total = rows_ctx.count();
        while (row < total) : (row += 1) table.push(profileRowHeight(rows_ctx, row));
    }
    const options: AppUi.VirtualListOptions = .{
        .id = ui.fmt("person-{d}", .{level_key}),
        // Nothing to cover when nothing is drawn, for the same reason the thread
        // list above says so: a list that declares items and builds none is
        // permanently "undercovered", and the runtime answers that by rebuilding
        // and re-laying out the whole view a second time, every time.
        .item_count = if (occluded) 0 else rows_ctx.count(),
        .item_extent = 0,
        .extent_estimate = rowExtentFromTable,
        .extent_context = table,
        .gap = 0,
        .padding = 0,
        .overscan = 3,
        .grow = 1,
        .viewport_fallback = window_height,
        .semantics = .{ .label = "Profile" },
        // Only a person's page pages. A topic and the bookmark list hold what
        // the store was asked for and have nothing older to reach.
        .on_reach_end = switch (header) {
            .person => .profile_older,
            else => null,
        },
    };
    const window = ui.virtualWindow(options);
    if (!occluded) recordProfileVisible(rows_ctx, level, window.first_visible_index, window.last_visible_index);
    if (!occluded and header == .person) {
        profile_notes.g_profile_bottom_in_view = window.start_index + window.itemCount() >= rows_ctx.count();
    }
    // An occluded level builds no rows, for the same reason a thread's does not:
    // the offset survives on the list's id and its content height, and six built
    // levels of anything cross the 1024-node ceiling that refuses a view whole.
    const rows = if (occluded)
        &[_]AppUi.Node{}
    else blk: {
        const built = ui.arena.alloc(AppUi.Node, window.itemCount()) catch return ui.column(.{}, .{});
        for (built, 0..) |*row, offset| row.* = profileRowAt(ui, rows_ctx, window.start_index + offset);
        break :blk built;
    };
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        // Back is the same for every kind of level; what the band names is
        // not. The header row under it still says what the list is.
        if (occluded) ui.spacer(0) else switch (header) {
            .person => |pk| profileHeaderBand(ui, model, pk),
            .topic => |t| levelBand(ui, model, elide(ui, ui.fmt("#{s}", .{t}), profile_band_name_max)),
            .bookmarks => levelBand(ui, model, "Bookmarks"),
        },
        ui.virtualList(options, window, .{rows}),
    });
}

/// The rows a profile level holds: the person, then their notes.
/// The rows of a stacked LIST level: a person's page, or a topic's.
///
/// One struct rather than two because the two differ in exactly one row, the
/// header, and in which notes they show. A parallel panel would mean a second
/// retained extent table, a second virtual list id scheme and a second copy of
/// the occlusion rules, all to draw the same list of notes under a different
/// first row.
pub const ProfileRows = struct {
    model: *const Model,
    header: LevelHeader,
    notes: []const Note,
    shown: []const usize,
    loading: bool,
    /// What closes the list. Only a person's page has one.
    footer: ProfileFooter = .none,

    const Row = union(enum) { person, topic, bookmarks, note: usize, empty, footer };

    /// The person this level is about, or all-zero when it is not about one.
    /// The callers below are all person-only paths reached from a `.person`
    /// row; the zero keeps them total rather than making each one a switch.
    pub fn subject(self: *const ProfileRows) [32]u8 {
        return switch (self.header) {
            .person => |pk| pk,
            else => @splat(0),
        };
    }

    pub fn count(self: *const ProfileRows) usize {
        // The person, then a row per note, or one quiet line when there are none.
        const body: usize = if (self.shown.len == 0) 1 else self.shown.len;
        return 1 + body + @intFromBool(self.footer != .none);
    }

    pub fn rowAt(self: *const ProfileRows, index: usize) Row {
        if (index == 0) return switch (self.header) {
            .person => .person,
            .topic => .topic,
            .bookmarks => .bookmarks,
        };
        if (self.shown.len == 0) return .empty;
        const i = index - 1;
        if (i == self.shown.len and self.footer != .none) return .footer;
        if (i >= self.shown.len) return .empty;
        return .{ .note = self.shown[i] };
    }
};

/// How a person's list ends.
const ProfileFooter = enum {
    /// More may be on the way, or the reader has not asked yet.
    none,
    /// A page of older notes is being fetched.
    loading,
    /// Every relay asked said there is nothing older.
    end,
    /// The page holds as many notes as it will, and there may be more.
    ceiling,
};

/// What closes the open person's list right now. Read at build time from the
/// round in flight and the latch, both of which the tick moves.
pub fn profileFooter(model: *const Model, pubkey: [32]u8, shown: usize) ProfileFooter {
    // An empty tab has its own line, and a list that says "that is all" before
    // it shows anything is saying something else.
    if (shown == 0) return .none;
    if (model.thread_notes_len >= profile_notes_max) return .ceiling;
    if (profileEndReached(pubkey)) return .end;
    if (profile_notes.g_profile_older_busy.load(.monotonic)) return .loading;
    return .none;
}
/// The line under the last note.
fn profileFooterRow(ui: *AppUi, footer: ProfileFooter) AppUi.Node {
    const p = theme.palette;
    const text: []const u8 = switch (footer) {
        .loading => "Looking for older notes…",
        .end => "That is everything the relays have from them.",
        .ceiling => ui.fmt("This page holds their latest {d} notes.", .{profile_notes_max}),
        .none => "",
    };
    // Under the notes, in their column, rather than at the window's left edge.
    return ui.row(.{ .grow = 1, .main = .center, .height = quiet_row_extent }, .{
        ui.row(.{ .width = feed_column_width, .cross = .center, .gap = 0 }, .{
            hgap(ui, row_pad_side),
            ui.paragraph(.{ .wrap = true, .style = .{ .foreground = p.text_dim } }, &.{.{ .text = text, .scale = mono_hint_scale }}),
            hgap(ui, row_pad_side),
        }),
    });
}

/// One person-page row's height, from the live rows. Typed for the same reason
/// `threadRowHeight` is.
fn profileRowHeight(rows: *const ProfileRows, index: usize) f32 {
    return switch (rows.rowAt(index)) {
        .person => profileCardExtent(rows),
        // The topic header is a title and two wrapped lines. Estimated rather
        // than measured, like every other row here: the retained table only
        // needs to be close enough that the scrollbar does not jump.
        .topic => 96,
        .bookmarks => 96,
        .note => |ni| noteRowEstimate(&rows.notes[ni], feed_row_chrome),
        .empty, .footer => quiet_row_extent,
    };
}

fn profileRowAt(ui: *AppUi, rows: *const ProfileRows, index: usize) AppUi.Node {
    return switch (rows.rowAt(index)) {
        .person => profileCard(ui, rows.model, rows.subject()),
        .topic => topicCard(ui, switch (rows.header) {
            .topic => |t| t,
            else => "",
        }),
        .bookmarks => bookmarksCard(ui),
        .note => |ni| noteCard(ui, &rows.notes[ni]),
        .empty => profileEmptyRow(ui, rows),
        .footer => profileFooterRow(ui, rows.footer),
    };
}

/// The header of a topic level: the tag, and what this list actually is.
///
/// Said plainly because it is not the same promise a feed makes. This is what
/// this reader's own relays have served and this machine has kept, not
/// everything on Nostr carrying the tag, and a topic view that implied the
/// latter would be claiming a search Plaza does not do.
fn topicCard(ui: *AppUi, topic: []const u8) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .padding = 16, .gap = 6, .cross = .stretch }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, ui.fmt("#{s}", .{topic})),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_secondary } },
            &.{.{ .text = "Notes carrying this tag, from your relays. Read from this machine first, so what is already here is on screen before anything is asked for." }},
        ),
    });
}

/// The header of the bookmark list.
///
/// It says where they live, because that is the part a reader cannot see. A
/// bookmark here is a NIP-51 kind:10003 published to their relays, so it
/// follows them to any client, and one saved privately elsewhere shows up here
/// too. Both halves are read; new ones are saved to the public half.
fn bookmarksCard(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .padding = 16, .gap = 6, .cross = .stretch }, .{
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Bookmarks"),
        ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_secondary } },
            &.{.{ .text = "Saved to your relays, so they follow you to any client. Private ones you saved elsewhere are shown here too. Notes this machine has not fetched are not listed." }},
        ),
    });
}

/// A stable, collision-free scroll identity for a thread level: the level index
/// in the high bits (distinct per position, so an ancestor keeps its key and
/// offset while deeper levels push and pop, and two levels never collide even if
/// the same note appears twice) and the root note id in the low bits (so when
/// the stack is saturated at `thread_depth_max` and `enterThread` replaces the
/// top root in place, the new level gets a fresh key and opens at the top rather
/// than inheriting the dropped thread's offset).
/// The same scheme `profileLevelKey` uses, over the topic's bytes: a level index
/// in the high bits so two levels never collide, and a hash of the topic in the
/// low bits so opening `#zig` twice at the same depth reuses its offset.
/// There is one bookmark list, so it needs no hash: a fixed key plus the level
/// index is enough to keep two stacked copies apart.
pub const bookmarks_level_key: u64 = 0x7000_0000_0000_0000;

pub fn topicLevelKey(level: usize, topic: []const u8) u64 {
    const hi = @as(u64, level) << 59;
    var hash: u64 = 1469598103934665603;
    for (topic) |c| {
        hash ^= c;
        hash *%= 1099511628211;
    }
    return hi | (hash & ((@as(u64, 1) << 59) - 1));
}

pub fn threadLevelKey(level: usize, root_id: i64) u64 {
    const hi = @as(u64, level) << 59;
    const lo = @as(u64, @intCast(root_id)) & ((@as(u64, 1) << 59) - 1);
    return hi | lo;
}

//! The compose sheet and the mention picker.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const compose = @import("compose.zig");
const drafts = @import("drafts.zig");
const profile_cache = @import("profile_cache.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const Note = main.Note;
const activePubkey = main.activePubkey;
const avatarTint = main.avatarTint;
const avatar_size = main.avatar_size;
const clipToChars = main.clipToChars;
const compose_capacity = main.compose_capacity;
const compose_editor_height = main.compose_editor_height;
const compose_editor_width = main.compose_editor_width;
const compose_sheet_width = main.compose_sheet_width;
const hgap = main.hgap;
const identityInk = main.identityInk;
const inFollowGraph = main.inFollowGraph;
const list_row_height = main.list_row_height;
const liveRelayCount = main.liveRelayCount;
const max_mention_tags = main.max_mention_tags;
const meAvatar = main.meAvatar;
const mentionExcluded = main.mentionExcluded;
const menuSurfacePlacedDismissing = main.menuSurfacePlacedDismissing;
const menu_scale = main.menu_scale;
const mono_chip_scale = main.mono_chip_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const mono_row_scale = main.mono_row_scale;
const notifiedBy = main.notifiedBy;
const nowSeconds = main.nowSeconds;
const personName = main.personName;
const postSecondsLeft = main.postSecondsLeft;
const pressRow = main.pressRow;
const settings_card_radius = main.settings_card_radius;
const settings_header_height = main.settings_header_height;
const settings_title_scale = main.settings_title_scale;
const stat_scale = main.stat_scale;
const thread_reply_cap = main.thread_reply_cap;
const uploadStrip = main.uploadStrip;
const vgap = main.vgap;

/// The compose sheet: a modal over the feed with the note field and the actions.
/// On demand from the titlebar's "New note", so the feed is not sharing the
/// window with a permanent composer. Escape or a click outside closes it.
pub fn composeSheet(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    // A PAGE, shaped like settings: a bar across the top, then the content in a
    // card down the middle of the window.
    //
    // It is not a modal for the reason settings is not: a modal is a translucent
    // scrim over the whole window, so every frame repaints the window entire and
    // the cost grows with it. On a 1600x1000 window a frame cost 183ms as a
    // sheet and 8ms as a page, and the worst of it was the app sitting idle with
    // a caret blinking in it.
    //
    // It was a bare rounded card flush against the top of the window for a
    // while, which is what a sheet looks like when the sheet around it is taken
    // away and nothing is put in its place.
    return ui.column(.{
        .grow = 1,
        .style_tokens = .{ .background = .background },
        .semantics = .{ .label = "New note" },
    }, .{
        composeHeader(ui, model),
        ui.el(.separator, .{ .style = .{ .background = p.divider_chrome } }, .{}),
        ui.scroll(.{ .grow = 1 }, .{
            ui.row(.{ .gap = 0 }, .{
                ui.spacer(1),
                ui.column(.{ .gap = 0, .width = compose_sheet_width }, .{
                    vgap(ui, 16),
                    // The writer and their words, side by side: the disc says
                    // whose voice this is, which is the one thing a composer
                    // must not leave ambiguous when a signer can be swapped.
                    ui.el(.card, .{
                        .padding = 14,
                        .style = .{ .background = p.surface_settings_card, .border = p.border_chip, .radius = settings_card_radius, .stroke_width = 1 },
                    }, .{
                        ui.row(.{ .gap = 0, .cross = .start }, .{
                            meAvatar(ui, avatar_size),
                            hgap(ui, 12),
                            ui.column(.{ .grow = 1, .gap = 0 }, .{
                                ui.el(.textarea, .{
                                    .text = model.draft(),
                                    .placeholder = "What's on your mind?",
                                    .on_input = AppUi.inputMsg(.draft_edit),
                                    .on_submit = .post,
                                    .width = compose_editor_width,
                                    .height = compose_editor_height,
                                    // The caret starts here. A composer you have
                                    // to click into before you can type is a
                                    // composer that opened for no reason.
                                    // Edge-triggered on mount, so it never
                                    // re-steals the caret on a later rebuild.
                                    .autofocus = true,
                                    .style = .{ .background = p.surface_settings_card, .border = p.surface_settings_card, .stroke_width = 0 },
                                }, .{}),
                                // Under the field, because the caret cannot be
                                // located and a picker that floats elsewhere is
                                // a guess about where the reader is looking.
                                mentionPicker(ui, model),
                            }),
                        }),
                    }),
                    composeNotifyRow(ui, model),
                    composeWarningRow(ui, model),
                    vgap(ui, 10),
                    // Under the words, where the picture's address will land.
                    // The servers it goes to are named here, before anything is
                    // picked, and again on the card before anything is sent.
                    uploadStrip(ui, model, .note),
                    vgap(ui, 10),
                    // What pressing Post will do, in the terms that matter: how
                    // far the note goes, and how much room is left when that
                    // starts to matter.
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 2),
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_dim } },
                            &.{.{ .text = composeReach(ui, model.draft().len, model.draft_dropped), .monospace = true, .scale = mono_meta_scale }},
                        ),
                        ui.spacer(1),
                        ui.paragraph(
                            .{ .style = .{ .foreground = p.text_muted } },
                            &.{.{ .text = "Cmd + Enter", .monospace = true, .scale = mono_hint_scale }},
                        ),
                        hgap(ui, 2),
                    }),
                    vgap(ui, 18),
                }),
                ui.spacer(1),
            }),
        }),
    });
}

/// The composer's content warning: a switch, and once it is on a line for the
/// reason. The reason is optional because the tag is the warning; a note with an
/// empty one is still covered for everyone who reads it.
///
/// Under the card and above the reach line, where the other things that change
/// who sees what (the people it notifies) already sit.
fn composeWarningRow(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.column(.{ .gap = 0 }, .{
        vgap(ui, 12),
        ui.el(.checkbox, .{
            .size = .sm,
            .checked = model.warn_on,
            .text = "Add a content warning",
            .on_toggle = Msg.warn_toggle,
            .style = .{
                .accent = p.surface_control_solid,
                .accent_foreground = p.on_accent,
                .border = p.border_radio,
                .radius = 4,
                .stroke_width = 1.5,
            },
            .semantics = .{ .label = "Add a content warning", .focusable = true },
        }, .{}),
        if (model.warn_on) vgap(ui, 8) else ui.spacer(0),
        if (model.warn_on) ui.inputGroup(
            .{ .semantics = .{ .label = "Content warning reason" } },
            ui.el(.textarea, .{
                .text = model.warn_draft(),
                .placeholder = "Reason (optional)",
                .on_input = AppUi.inputMsg(.warn_edit),
                .height = 40,
            }, .{}),
            null,
        ) else ui.spacer(0),
        if (model.warn_on) vgap(ui, 6) else ui.spacer(0),
        if (model.warn_on) ui.paragraph(
            .{ .wrap = true, .style = .{ .foreground = p.text_faint } },
            &.{.{ .text = "Readers see the reason and a button to show the note. Its pictures are not fetched until they do.", .scale = mono_hint_scale }},
        ) else ui.spacer(0),
    });
}

/// The composer's top bar: the way out on the left, what this is in the middle,
/// and the verb on the right. The same band settings wears, so the two full
/// screens in the app are not two different shapes.
fn composeHeader(ui: *AppUi, model: *const Model) AppUi.Node {
    const p = theme.palette;
    return ui.row(.{ .cross = .center, .gap = 0, .height = settings_header_height, .padding = 0.01 }, .{
        hgap(ui, 10),
        ui.button(.{ .size = .sm, .variant = .ghost, .on_press = .close_compose }, "Cancel"),
        ui.spacer(1),
        ui.paragraph(
            .{ .style = .{ .foreground = p.text_sheet_title } },
            &.{.{ .text = "New note", .weight = .medium, .scale = settings_title_scale }},
        ),
        ui.spacer(1),
        if (compose.g_post_due_s != 0)
            // Both shapes the request asked for, in one control: it counts, and
            // pressing it takes the note back. Never disabled while it counts,
            // because the whole value of the pause is being able to press it.
            ui.button(
                .{ .size = .sm, .variant = .secondary, .on_press = .post },
                std.fmt.allocPrint(ui.arena, "Undo · {d}", .{postSecondsLeft(compose.g_post_due_s, nowSeconds())}) catch "Undo",
            )
        else
            ui.button(.{ .size = .sm, .variant = .primary, .disabled = model.draft_empty(), .on_press = .post }, "Post"),
        hgap(ui, 10),
    });
}

/// Replaces the `@word` being typed with a real `nostr:npub…` reference.
///
/// A plain `@name` is a string; only the reference is a link that another
/// client can resolve to a person, and it is what the note's own renderer turns
/// back into a name when it is read. The picker exists to make that the easy
/// path rather than the knowledgeable one.
pub fn insertMention(model: *Model, pubkey: [32]u8) void {
    const text = model.draft();
    // Through the same reader the picker used, so the cut is the run being
    // typed and never, say, the domain of an address written earlier.
    const query = mentionQuery(text) orelse return;
    const at = text.len - query.len - 1;
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const npub = nostr.nip19.encodeNpub(fba.allocator(), pubkey) catch return;
    // Sized to what the draft can actually hold, so an insert that will not fit
    // is REFUSED rather than written short: the buffer truncates in silence,
    // and half a bech32 reference is one no client can resolve, published
    // without a word of warning.
    var buf: [compose_capacity]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, "{s}nostr:{s} ", .{ text[0..at], npub }) catch return;
    model.draft_buffer = @TypeOf(model.draft_buffer).init(written);
    drafts.g_draft_dirty = true;
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
    for (&profile_cache.g_profiles) |*pr| {
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
    if (model.mention_dismissed) return ui.spacer(0);
    const query = mentionQuery(model.draft()) orelse return ui.spacer(0);
    const names = mentionCandidates(ui, query);
    if (names.len == 0) return ui.spacer(0);
    const rows = ui.arena.alloc(AppUi.Node, names.len + 1) catch return ui.spacer(0);
    for (names, rows[0..names.len], 0..) |c, *row, i| {
        const tint = avatarTint(c.pubkey);
        const hexdigits = "0123456789abcdef";
        row.* = ui.el(.list_item, .{
            .padding = 0.01,
            .height = list_row_height,
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
                ui.paragraph(.{ .style = .{ .foreground = identityInk() } }, &.{.{ .text = ui.fmt("@{s}", .{c.handle}), .scale = mono_row_scale }})
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
    return menuSurfacePlacedDismissing(ui, 320, .below, .start, Msg.close_mentions, rows);
}

/// How far a note will go, said before it goes rather than after: the relays
/// that will take a write, and that Plaza imposes no length of its own.
/// Who this note will notify, as names you can switch off.
///
/// Nothing here is new information at publish time: it is the same set the
/// event carries, shown before it goes out. A reply can tag a dozen people who
/// were merely present in a thread, and the first anybody knew about it used to
/// be somebody answering a conversation they had left.
/// The composer's notify row, derived from the draft as it stands.
fn composeNotifyRow(ui: *AppUi, model: *const Model) AppUi.Node {
    var people: [max_mention_tags][32]u8 = undefined;
    const n = notifiedBy(model.draft(), &people);
    if (n == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{ vgap(ui, 10), notifyChips(ui, model, people[0..n]) });
}

/// The reply's notify row: whoever the text names, plus everybody already in
/// the thread, which is the set that surprises people.
pub fn replyNotifyRow(ui: *AppUi, model: *const Model, root: *const Note) AppUi.Node {
    var people: [max_mention_tags][32]u8 = undefined;
    var n = notifiedBy(model.reply_draft(), &people);
    const me = activePubkey();
    var pool: [1 + thread_reply_cap][32]u8 = undefined;
    var pool_len: usize = 0;
    pool[0] = root.pubkey;
    pool_len = 1;
    for (model.thread_notes[0..model.thread_notes_len]) |note| {
        if (pool_len == pool.len) break;
        pool[pool_len] = note.pubkey;
        pool_len += 1;
    }
    for (pool[0..pool_len]) |pubkey| {
        if (n == people.len) break;
        if (me) |mine| {
            if (std.mem.eql(u8, &mine, &pubkey)) continue;
        }
        var dup = false;
        for (people[0..n]) |seen| {
            if (std.mem.eql(u8, &seen, &pubkey)) dup = true;
        }
        if (dup) continue;
        people[n] = pubkey;
        n += 1;
    }
    if (n == 0) return ui.spacer(0);
    return ui.column(.{ .gap = 0 }, .{ vgap(ui, 8), notifyChips(ui, model, people[0..n]) });
}

fn notifyChips(ui: *AppUi, model: *const Model, people: []const [32]u8) AppUi.Node {
    const p = theme.palette;
    if (people.len == 0) return ui.spacer(0);

    // Chunked into rows by hand, because `wrap` is a text property in this
    // toolkit and not a row one: a single row of a dozen chips would run off
    // the side of the composer rather than folding under itself.
    //
    // Two per row, and the name clipped. Three of them blew 35px past the right
    // edge of the narrowest window the app allows, which the layout guard
    // caught: a chip is only as wide as the name inside it, and a display name
    // has no length any of this controls.
    const per_row = 2;
    const row_count = (people.len + per_row - 1) / per_row;
    const rows = ui.arena.alloc(AppUi.Node, row_count + 1) catch return ui.spacer(0);
    rows[0] = ui.paragraph(
        .{ .style = .{ .foreground = p.text_dim } },
        &.{.{ .text = "Notifies", .scale = stat_scale }},
    );

    var placed: usize = 0;
    for (rows[1..]) |*row| {
        const take = @min(per_row, people.len - placed);
        const kids = ui.arena.alloc(AppUi.Node, take) catch return ui.spacer(0);
        for (people[placed..][0..take], kids) |pubkey, *kid| {
            const off = mentionExcluded(model.mentionsOff(), pubkey);
            // Switched off stays on screen, dimmed, rather than disappearing:
            // a chip that vanished when pressed would leave nothing to press
            // to bring the person back.
            // The press and its focus ring live on the outer row, the chip's
            // fill and border on the panel inside it: a list row draws a fill
            // and a ring and no border.
            kid.* = pressRow(ui, .{
                .on_press = Msg{ .toggle_mention_off = pubkey },
                .style = .{ .radius = 999, .quiet_hover = true },
                .semantics = .{ .role = .button, .label = if (off) "Not notifying, press to switch back on" else "Notifying, press to switch off", .focusable = true },
            }, .{
                ui.el(.panel, .{
                    .padding = 0.01,
                    .style = .{
                        .background = if (off) p.surface_rail_tile else p.surface_input,
                        .border = p.border_chip,
                        .radius = 999,
                        .stroke_width = 1,
                    },
                }, .{
                    ui.row(.{ .cross = .center, .gap = 0 }, .{
                        hgap(ui, 10),
                        ui.paragraph(
                            .{ .style = .{ .foreground = if (off) p.text_muted else p.text_secondary } },
                            &.{.{ .text = clipToChars(personName(ui, pubkey), 14, 42), .scale = stat_scale }},
                        ),
                        hgap(ui, 10),
                        vgap(ui, 24),
                    }),
                }),
            });
        }
        placed += take;
        row.* = ui.row(.{ .cross = .center, .gap = 6 }, kids);
    }
    return ui.column(.{ .gap = 6 }, rows);
}
pub fn composeReach(ui: *AppUi, written: usize, dropped: usize) []const u8 {
    // The overflow first, because it is the only thing here the writer has to
    // act on: some of what they pasted is not in the box and they cannot see
    // which part.
    if (dropped > 0) {
        return ui.fmt("{d} characters did not fit and were not kept", .{dropped});
    }
    // The room left, once there is little enough of it to matter. A composer
    // that silently stops accepting characters is the bug this replaces, and a
    // counter that is always on screen is a nag for the ninety-nine notes that
    // will never approach the limit.
    const left = compose_capacity -| written;
    if (left <= compose_capacity / 4) {
        const live_now = liveRelayCount();
        if (live_now == 0) return ui.fmt("{d} left · no relay is answering", .{left});
        return ui.fmt("posts to {d} {s} · {d} left", .{ live_now, if (live_now == 1) "relay" else "relays", left });
    }
    const live = liveRelayCount();
    if (live == 0) return "no relay is answering · it will wait in the outbox";
    return ui.fmt("posts to {d} {s}", .{ live, if (live == 1) "relay" else "relays" });
}

pub fn insertMentionForTest(model: *Model, pubkey: [32]u8) void {
    insertMention(model, pubkey);
}

pub fn composeReachForTest(arena: std.mem.Allocator, written: usize, dropped: usize) []const u8 {
    var ui = AppUi.init(arena);
    return composeReach(&ui, written, dropped);
}

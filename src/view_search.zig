//! The search sheet: results, sources, and the empty states.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const theme = @import("theme.zig");
const main = @import("main.zig");
const people_search = @import("people_search.zig");
const search = @import("search.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

// ---- from main.zig
const AppUi = main.AppUi;
const Msg = main.Msg;
const SearchInput = main.SearchInput;
const SearchRow = main.SearchRow;
const avatarTint = main.avatarTint;
const elide = main.elide;
const identityInk = main.identityInk;
const lookupProfile = main.lookupProfile;
const menu_scale = main.menu_scale;
const mono_chip_scale = main.mono_chip_scale;
const mono_hint_scale = main.mono_hint_scale;
const mono_meta_scale = main.mono_meta_scale;
const mono_row_scale = main.mono_row_scale;
const personNpubShort = main.personNpubShort;
const relayShortName = main.relayShortName;
const searchRelayStatus = main.searchRelayStatus;
const searchRelays = main.searchRelays;
const search_rows_max = main.search_rows_max;

/// The width of the search sheet. The dialog and the card inside it share the
/// one number, for the reason `join_sheet_width` gives.
pub const search_sheet_width: f32 = 520;
/// How tall the results are before they scroll.
const search_results_height: f32 = 280;
/// The empty field's box, and what one relay's line costs under the list.
const search_empty_height: f32 = 140;
const search_relay_line_height: f32 = 19;
/// What a line of text in the card may span: the card less its padding. Wrapped
/// text is given this as a definite width because a leaf measures one line at
/// its natural width otherwise. The body is also given a definite HEIGHT, below,
/// because the card is sized from its content and wrapped text is not counted at
/// its wrapped height: the last control ran 16pt out of the bottom of the card.
/// A fixed body also means the sheet does not change size as results arrive.
const search_sheet_inner: f32 = search_sheet_width - 48;
/// Characters the second line of a row may spend on each of its two parts.
const search_identity_max = 24;
const search_source_max = 44;
/// Everything between the field and its button: what to do with an empty field,
/// or the people found and the relays that were asked.
pub fn searchBody(ui: *AppUi, kind: SearchInput) AppUi.Node {
    const p = theme.palette;
    if (kind == .blank) return ui.column(.{ .height = search_empty_height }, .{searchEmpty(ui)});
    // An address is opened, not searched for, so there is nothing to list, and
    // a key is not searched for at all.
    if (kind == .address or kind == .key) return ui.spacer(0);

    const rows = people_search.g_search_rows[0..people_search.g_search_len];
    var nodes: [search_rows_max + 2]AppUi.Node = undefined;
    var n: usize = 0;
    var locals: usize = 0;
    for (rows) |r| {
        if (r.local) locals += 1;
    }
    if (locals > 0) {
        nodes[n] = searchSectionLabel(ui, ui.fmt("ON THIS DEVICE  {d}", .{locals}));
        n += 1;
        for (rows) |*r| {
            if (!r.local) continue;
            nodes[n] = searchRow(ui, r);
            n += 1;
        }
    }
    if (rows.len > locals) {
        nodes[n] = searchSectionLabel(ui, ui.fmt("FROM SEARCH RELAYS  {d}", .{rows.len - locals}));
        n += 1;
        for (rows) |*r| {
            if (r.local) continue;
            nodes[n] = searchRow(ui, r);
            n += 1;
        }
    }
    // Boxed to the list's own height, so the relays keep their place under it
    // whether or not anybody has turned up.
    const results: AppUi.Node = if (rows.len == 0)
        ui.column(.{ .height = if (kind == .nip05) 0 else search_results_height }, .{
            ui.paragraph(
                .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_dim } },
                &.{.{ .text = searchNothingYet(kind), .scale = mono_hint_scale }},
            ),
        })
    else
        ui.scroll(.{ .height = search_results_height }, .{ui.column(.{ .gap = 2 }, .{nodes[0..n]})});
    // The relays are only worth naming when a name is being searched for: for a
    // NIP-05 address they are not the ones being asked.
    // Nothing to list and no relays to name: the line alone, not a tall empty box.
    if (kind == .nip05 and rows.len == 0) return results;
    const relay_lines: f32 = @floatFromInt(searchRelays().len);
    const height = search_results_height + if (kind == .term) 18 + relay_lines * search_relay_line_height else 0;
    return ui.column(.{ .height = height, .gap = 10 }, .{
        results,
        if (kind == .term) searchRelayLines(ui) else ui.spacer(0),
    });
}

/// What the list says when it has nothing in it, which depends on whether the
/// relays have been heard from.
fn searchNothingYet(kind: SearchInput) []const u8 {
    // An address is asked of its domain; the search relays are not part of it.
    if (kind == .nip05) return "No one on this device has that address.";
    var asking = false;
    var answered = false;
    for (searchRelays(), 0..) |_, i| {
        switch (searchRelayStatus(i).state) {
            .asking => asking = true,
            .answered, .declined, .unreachable_, .silent => answered = true,
            else => {},
        }
    }
    if (asking) return "No one on this device matches. Asking the search relays.";
    if (answered) return "No one on this device matches, and the search relays found no one.";
    return "No one on this device matches. The search relays are asked once you stop typing.";
}

fn searchSectionLabel(ui: *AppUi, text: []const u8) AppUi.Node {
    return ui.paragraph(.{ .style = .{ .foreground = theme.palette.text_label } }, &.{.{ .text = text, .monospace = true, .scale = mono_meta_scale }});
}

/// The empty field: what it takes, and where a name goes when it is searched for.
fn searchEmpty(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const relays = searchRelays();
    var hosts: [search.relays_max][]const u8 = undefined;
    for (relays, 0..) |url, i| hosts[i] = relayShortName(url);
    return ui.column(.{ .gap = 8 }, .{
        ui.paragraph(
            .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_body } },
            &.{.{ .text = "Type a name to look through the profiles on this device. Nothing leaves it until you stop typing.", .scale = menu_scale }},
        ),
        ui.paragraph(
            .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_muted } },
            &.{.{ .text = "An npub, an nprofile, name@domain or a link to a note or a place goes straight there.", .scale = menu_scale }},
        ),
        ui.paragraph(
            .{ .wrap = true, .width = search_sheet_inner, .style = .{ .foreground = p.text_dim } },
            &.{.{ .text = ui.fmt("Then the search relays are asked for the name: {s}.", .{joinStrings(ui, hosts[0..relays.len], ", ")}), .scale = mono_hint_scale }},
        ),
    });
}

fn joinStrings(ui: *AppUi, parts: []const []const u8, sep: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) out.appendSlice(ui.arena, sep) catch return "";
        out.appendSlice(ui.arena, part) catch return "";
    }
    return out.items;
}

/// One line per search relay, so a relay that found no one is named rather than
/// absent, and one that could not be reached says that instead.
fn searchRelayLines(ui: *AppUi) AppUi.Node {
    const p = theme.palette;
    const urls = searchRelays();
    var lines: [search.relays_max]AppUi.Node = undefined;
    for (urls, 0..) |url, i| {
        const st = searchRelayStatus(i);
        var buf: [32]u8 = undefined;
        const said = search.describe(&buf, st.state, st.count);
        const ink = switch (st.state) {
            .answered => if (st.count > 0) p.text_body_strong else p.text_muted,
            .unreachable_, .declined, .silent => p.status_warning_text,
            else => p.text_dim,
        };
        lines[i] = ui.row(.{ .cross = .center, .gap = 0 }, .{
            ui.paragraph(.{ .style = .{ .foreground = p.text_muted } }, &.{.{ .text = relayShortName(url), .monospace = true, .scale = mono_meta_scale }}),
            ui.spacer(1),
            ui.paragraph(.{ .style = .{ .foreground = ink } }, &.{.{ .text = ui.fmt("{s}", .{said}), .monospace = true, .scale = mono_meta_scale }}),
        });
    }
    return ui.column(.{ .gap = 3 }, .{
        ui.el(.separator, .{ .style = .{ .background = p.divider_row } }, .{}),
        lines[0..urls.len],
    });
}

/// Where a result came from, in words: this machine, and each relay that named
/// them. Long lists give the first and a count, so the line stays on its row.
fn searchSourceText(ui: *AppUi, row: *const SearchRow) []const u8 {
    var parts: [search.relays_max + 1][]const u8 = undefined;
    var n: usize = 0;
    if (row.local) {
        parts[n] = "this device";
        n += 1;
    }
    for (searchRelays(), 0..) |url, i| {
        if (i >= search.relays_max) break;
        if (row.relays & (@as(u8, 1) << @intCast(i)) == 0) continue;
        parts[n] = relayShortName(url);
        n += 1;
    }
    const whole = joinStrings(ui, parts[0..n], ", ");
    if (whole.len <= search_source_max or n < 2) return whole;
    return ui.fmt("{s} +{d}", .{ parts[0], n - 1 });
}

/// One person in the results: the name, what they are called elsewhere, and
/// where this machine heard of them.
fn searchRow(ui: *AppUi, row: *const SearchRow) AppUi.Node {
    const p = theme.palette;
    const pk = row.pubkey;
    const prof = lookupProfile(pk);
    const name = if (prof) |pr| (if (pr.name_len > 0) pr.name() else "") else "";
    const shown = if (name.len > 0) name else personNpubShort(ui, pk);
    const verified = if (prof) |pr| pr.nip05_state == .verified else false;
    // The address only once it has been checked, as everywhere else in the app:
    // one nobody has confirmed is a claim, not a credential. The exception is
    // an address the term matched, shown plainly so a row is never a mystery
    // about why it is in the list.
    const identity: []const u8 = blk: {
        const pr = prof orelse break :blk "";
        if (verified) break :blk pr.nip05();
        if (pr.nip05_len > 0 and search.quality(pr.nip05(), people_search.g_search_term[0..people_search.g_search_term_len]) != null) break :blk pr.nip05();
        if (pr.username_len > 0) break :blk ui.fmt("@{s}", .{pr.username()});
        break :blk "";
    };
    const tint = avatarTint(pk);
    const hexdigits = "0123456789abcdef";

    // Built as slices so a line with nothing to say costs no node.
    var name_line: [2]AppUi.Node = undefined;
    var name_n: usize = 1;
    name_line[0] = ui.paragraph(.{ .style = .{ .foreground = p.text_primary } }, &.{.{ .text = elide(ui, shown, 40), .weight = .medium, .scale = menu_scale }});
    if (verified) {
        name_line[1] = ui.icon(.{ .width = 11, .height = 11, .style = .{ .foreground = p.status_success } }, "check-circle");
        name_n = 2;
    }
    var second: [2]AppUi.Node = undefined;
    var second_n: usize = 0;
    if (identity.len > 0) {
        second[second_n] = ui.paragraph(.{ .style = .{ .foreground = identityInk() } }, &.{.{ .text = elide(ui, identity, search_identity_max), .scale = mono_row_scale }});
        second_n += 1;
    }
    second[second_n] = ui.paragraph(.{ .style = .{ .foreground = p.text_dim } }, &.{.{ .text = searchSourceText(ui, row), .monospace = true, .scale = mono_chip_scale }});
    second_n += 1;

    return ui.el(.list_item, .{
        .padding = 6,
        .gap = 10,
        .cross = .center,
        .on_press = Msg{ .search_pick = pk },
        .style = .{ .radius = 8, .quiet_hover = true },
        .semantics = .{ .role = .button, .label = shown, .focusable = true },
    }, .{
        ui.avatar(.{
            .image = 0,
            .width = 30,
            .height = 30,
            .style = .{ .background = tint.bg, .border = tint.border, .foreground = tint.glyph, .stroke_width = 1 },
        }, ui.fmt("{c}{c}", .{ hexdigits[pk[0] >> 4], hexdigits[pk[0] & 0x0f] })),
        ui.column(.{ .grow = 1, .gap = 2 }, .{
            ui.row(.{ .cross = .center, .gap = 5 }, .{name_line[0..name_n]}),
            ui.row(.{ .cross = .center, .gap = 8 }, .{second[0..second_n]}),
        }),
    });
}

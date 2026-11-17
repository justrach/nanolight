//! Clipboard history in the panel, where the rows were (as Settings is):
//! the query filters it, ↑/↓ move, the right side shows the whole text.
//! Return copies it and hides the panel; ⌘⌫ deletes it; esc goes back to
//! search. Without a host (tests) it still draws; Return writes the
//! Tester's clipboard, not the system's.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const panel = @import("view.zig");
const clipboard = @import("clipboard.zig");
const now = @import("account.zig").now;
const Palette = panel.Palette;

const row_h = 36;
const list_w = 260;
const list_pad = 6;
/// The rows that fit between the header and the footer.
const fit: usize = @intFromFloat((panel.rows_height - panel.header_h - panel.footer_h - 2 - list_pad * 2) / row_h);

pub const View = struct {
    open: bool = false,
    /// Into the entries the filter lets through.
    sel: usize = 0,
    /// The first row drawn: the list follows the selection, not the wheel.
    top: usize = 0,
    /// The filter the selection was made under; a new one starts at the top.
    filter: u64 = 0,

    pub fn show(v: *View) void {
        v.* = .{ .open = true };
    }

    pub fn hide(v: *View) void {
        v.open = false;
    }

    /// Drawn in place of the rows, its keys taken before the field's.
    pub fn inPanel(v: *View, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        var buf: [clipboard.max_items]usize = undefined;
        if (!v.keys(c, n, matches(n, &buf))) return;
        const h = n.follow(panel.rows_height);
        const box = ui.div(c).column().wFull().h(h).clip();
        defer box.end();
        const submitted = header(c, n, p);
        const shown = matches(n, &buf);
        const f = std.hash.Wyhash.hash(0, n.query.text());
        if (f != v.filter) v.* = .{ .open = true, .filter = f };
        if (v.sel >= shown.len) v.sel = shown.len -| 1;
        v.top = std.math.clamp(v.top, (v.sel + 1) -| fit, v.sel);
        ui.div(c).wFull().h(1).bg(p.hair).end();
        {
            const mid = ui.div(c).row().wFull().grow().clip();
            defer mid.end();
            if (shown.len == 0) empty(c, n, p) else v.body(c, n, p, shown);
        }
        if (submitted and shown.len > 0) v.copy(c, n, shown[v.sel]);
        footer(c, n, p, shown.len > 0);
    }

    /// Arrows, ⌘⌫ and esc. False once the view has closed.
    fn keys(v: *View, c: *ui.Context, n: *panel.Nanolight, shown: []const usize) bool {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) {
            v.hide();
            n.query.clear();
            return false;
        }
        const len = shown.len;
        if (len == 0) return true;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) v.sel = (v.sel + 1) % len;
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) v.sel = (v.sel + len - 1) % len;
        if (c.shortcut(.{ .key = 0x7f, .cmd = true })) n.history.?.remove(shown[@min(v.sel, len - 1)]);
        return true;
    }

    /// Back on the clipboard, first in the history, the panel gone.
    fn copy(v: *View, c: *ui.Context, n: *panel.Nanolight, i: usize) void {
        const h = n.history.?;
        c.clipboard.write(c.clipboard.ctx, h.items.items[i].text);
        // Already kept: push only moves it to the front, so it can't fail.
        h.push(h.items.items[i].text) catch {};
        v.hide();
        n.query.clear();
        if (n.host) |host| host.hide(host.ctx);
    }

    fn body(v: *View, c: *ui.Context, n: *panel.Nanolight, p: Palette, shown: []const usize) void {
        const items = n.history.?.items.items;
        {
            const col = ui.div(c).column().w(list_w).hFull().p(list_pad);
            defer col.end();
            for (shown[v.top..@min(shown.len, v.top + fit)], v.top..) |k, i| {
                ui.key(c, c.print("clip-{d}", .{i}));
                const r = ui.div(c).row().wFull().h(row_h).px(10).gap(8).itemsCenter().rounded(8).control();
                defer r.end();
                if (i == v.sel) _ = r.bg(p.sel).border(p.rim);
                if (r.clicked()) {
                    if (i == v.sel) return v.copy(c, n, k);
                    v.sel = i;
                }
                ui.text(c, snippet(items[k].text), .{ .size = 13, .color = p.text, .truncate = .ellipsis });
                ui.spacer(c);
                ui.text(c, age(c, items[k].at), .{ .size = 11.5, .color = p.sub.alpha(0.8), .tabular = true });
            }
        }
        ui.div(c).w(1).hFull().bg(p.hair).end();
        const pre = ui.div(c).column().grow().hFull().px(16).py(12).clip();
        defer pre.end();
        // A line count, not a scroll: 64 KB laid out whole would cost every key.
        ui.text(c, items[shown[v.sel]].text, .{ .size = 13, .color = p.text, .wrap = true, .max_lines = 18 });
    }
};

/// The entries whose text holds the query (ASCII case folded), newest first.
fn matches(n: *panel.Nanolight, buf: *[clipboard.max_items]usize) []const usize {
    const h = n.history orelse return &.{};
    if (!h.on) return &.{};
    const q = std.mem.trim(u8, n.query.text(), " ");
    var len: usize = 0;
    for (h.items.items, 0..) |e, i| {
        if (len == buf.len) break;
        if (std.ascii.findIgnoreCase(e.text, q) == null) continue;
        buf[len] = i;
        len += 1;
    }
    return buf[0..len];
}

/// The first line with words on it.
fn snippet(t: []const u8) []const u8 {
    const s = std.mem.trimStart(u8, t, " \t\r\n");
    return s[0 .. std.mem.indexOfAny(u8, s, "\r\n") orelse s.len];
}

fn age(c: *ui.Context, at: i64) []const u8 {
    const d = @max(0, now() - at);
    if (d < 60) return "now";
    if (d < 3600) return c.print("{d}m", .{@divTrunc(d, 60)});
    if (d < 86400) return c.print("{d}h", .{@divTrunc(d, 3600)});
    return c.print("{d}d", .{@divTrunc(d, 86400)});
}

fn header(c: *ui.Context, n: *panel.Nanolight, p: Palette) bool {
    const bar = ui.div(c).row().wFull().h(panel.header_h).px(18).gap(12).itemsCenter();
    defer bar.end();
    ui.icon(c, "doc.on.clipboard", .{ .size = 17, .weight = .medium, .color = n.theme.hue(c.theme.dark) orelse p.sub, .frame = 22 });
    return ui.textField(c, &n.query, .{
        .bare = true,
        .size = n.theme.fieldSize(),
        .width = .fill,
        .placeholder = "Search clipboard history…",
        .placeholder_color = p.sub.alpha(0.75),
        .color = p.text,
    }).submitted;
}

fn empty(c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
    const box = ui.div(c).column().grow().hFull().center().gap(4);
    defer box.end();
    const h = n.history orelse return;
    const say: [2][]const u8 = if (!h.on)
        .{ "Clipboard History is off", "Turn it on in Settings" }
    else if (h.items.items.len == 0)
        .{ "Nothing copied yet", "Text you copy shows here" }
    else
        .{ "No matches", "" };
    ui.text(c, say[0], .{ .size = 14, .weight = .medium, .color = p.text });
    if (say[1].len > 0) ui.text(c, say[1], .{ .size = 12, .color = p.sub });
}

fn footer(c: *ui.Context, n: *panel.Nanolight, p: Palette, any: bool) void {
    ui.div(c).wFull().h(1).bg(p.hair).end();
    const bar = ui.div(c).row().wFull().h(panel.footer_h).px(16).gap(8).itemsCenter();
    defer bar.end();
    if (n.history) |h| if (h.items.items.len > 0) {
        ui.key(c, "clip-clear");
        const b = ui.div(c).row().h(26).px(10).rounded(7).itemsCenter().control().hover(p.sel);
        defer b.end();
        if (b.clicked()) h.clear();
        ui.text(c, "Clear All", .{ .size = 12, .weight = .medium, .color = p.sub });
    };
    ui.spacer(c);
    if (any) {
        ui.text(c, "Copy", .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
        ui.kbd(c, "↩");
        ui.text(c, "Delete", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, @import("results.zig").mod ++ "⌫");
        ui.div(c).w(1).h(14).bg(p.hair).end();
    }
    ui.text(c, "Back", .{ .size = 12, .color = p.sub.alpha(0.8) });
    ui.kbd(c, "esc");
}

test "the filter folds case and keeps newest first" {
    var h: clipboard.History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    for ([_][]const u8{ "Zig build", "lunch", "zig TEST" }) |t| try h.push(t);
    var ix: @import("apps.zig").Index = .init(std.testing.allocator);
    defer ix.deinit();
    var n: panel.Nanolight = .{ .index = &ix, .history = &h };
    defer n.query.deinit();
    n.query.set("ZIG");
    var buf: [clipboard.max_items]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, matches(&n, &buf));
    try std.testing.expectEqualStrings("next", snippet("\n  next\nline"));
}

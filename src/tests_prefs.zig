//! Issues #8, #9 and #10 through the Tester: the panel's first frame on
//! the Mac, searches sent to the browser, and the two Settings rows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const settings_view = @import("settings_view.zig");
const tests = @import("tests.zig");
const suggest = @import("suggest.zig");
const clipboard = @import("clipboard.zig");
const mac = @import("builtin").os.tag == .macos;
const placeholder = "Search apps, do math, ask Grok…";

/// Where the field's placeholder is in the first frame after the panel
/// shows, and once it has settled.
fn firstAndSettled(fades: bool) ![2]ui.Rect {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix, .window_fades = fades, .margin = view.shadow_margin };
    defer s.query.deinit();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width + 2 * view.shadow_margin, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.frame();
    const first = t.findText(placeholder) orelse return error.NoField;
    t.settle(1);
    return .{ first, t.findText(placeholder) orelse return error.NoField };
}

test "on the Mac the panel's first frame is where it settles (issue #9)" {
    // The window fades in, the system's glass with it: the panel drawn
    // over that glass comes in at once, not from above and transparent.
    const r = try firstAndSettled(true);
    try std.testing.expectEqual(r[1].y, r[0].y);
    try std.testing.expectEqual(r[1].x, r[0].x);
    // Over its own glass (the film, the promo) it still comes in: this is
    // what the Mac's panel did over a glass that didn't.
    const own = try firstAndSettled(false);
    try std.testing.expect(own[0].y < own[1].y);
}

fn findRow(t: *ui.Tester, s: *view.Nanolight, words: []const u8) void {
    tests.press(t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = words } });
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
}

test "searches can open in the browser, ⌘↩ showing them in the panel (issue #10)" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix, .searches_out = true };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    // Return: the browser, and the panel goes.
    findRow(&t, &s, "pizza");
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizza", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden and web.page_len == null and !s.previewing);
    // ⌘↩: the page in the panel, which stays.
    web.probe = .{};
    s.reveal();
    t.settle(1);
    findRow(&t, &s, "pasta");
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pasta", web.page[0..web.page_len.?]);
    try std.testing.expect(!web.probe.hidden and web.probe.opened_len == 0 and s.previewing);
}

test "Settings hides the menu bar icon and sends searches out (issues #8, #10)" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try t.clickText("Show in Menu Bar");
    t.settle(1);
    try std.testing.expect(!prefs.menu_bar_on);
    try t.clickText("Open Searches in Browser");
    t.settle(1);
    try std.testing.expect(s.searches_out and prefs.searches_out.?);
    // Twice more each: back as they were.
    try t.clickText("Show in Menu Bar");
    try t.clickText("Open Searches in Browser");
    t.settle(1);
    try std.testing.expect(prefs.menu_bar_on and !s.searches_out and !prefs.searches_out.?);
    // The rows fit: the last one is inside Settings, Settings in the window.
    const quit = t.findText("Back").?;
    try std.testing.expect(quit.y + quit.h <= settings_view.height);
    try std.testing.expect(settings_view.height <= view.max_height);
}

test "Settings' header picks the panel's theme, and keeps it" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.findText("System") != null);
    // ↑ from the first row: round to the header's swatches; → twice.
    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    _ = t.shortcut(.{ .key = ui.Shortcut.right });
    _ = t.shortcut(.{ .key = ui.Shortcut.right });
    t.settle(1);
    try std.testing.expectEqual(view.Theme.forest, s.theme);
    try std.testing.expectEqual(view.Theme.forest, prefs.theme.?);
    try std.testing.expect(t.findText("Forest") != null);
    // ← past the first: round to the last.
    _ = t.shortcut(.{ .key = ui.Shortcut.left });
    _ = t.shortcut(.{ .key = ui.Shortcut.left });
    _ = t.shortcut(.{ .key = ui.Shortcut.left });
    t.settle(1);
    try std.testing.expectEqual(view.Theme.violet, prefs.theme.?);
    // In the header, which the rows can't push out of sight.
    const name = t.findText("Violet").?;
    try std.testing.expect(name.y + name.h <= view.header_h);
}

test "System Settings' panes open from the panel, which stays in its window (#12)" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("System Settings", "/System/Applications/System Settings.app");
    for ([_][]const u8{ "Sound A", "Sound B", "Sound C", "Sound D", "Sound E", "Sound F" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    tests.press(&t, &.{.{ .insert = "login items" }});
    try std.testing.expect(t.hasText("Login Items & Extensions"));
    try std.testing.expect(t.hasText("Open in System Settings"));
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden);
    // Every app row, a pane, and Google's completions: the longest list
    // with four sections, its pane in view once the selection reaches it.
    s.reveal();
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "sound" } });
    var four: @import("suggest.zig").List = .{};
    for ([_][]const u8{ "sound 1", "sound 2", "sound 3", "sound 4" }) |w| four.push(w);
    s.answered("sound", &four);
    t.settle(1);
    for (0..s.res.n) |_| {
        if (s.res.rows[s.sel].kind == .pane) break;
        _ = t.shortcut(.{ .key = ui.Shortcut.down });
    }
    t.frame();
    try std.testing.expect(t.hasText("System Settings"));
    try std.testing.expect(s.height() <= view.max_height);
}

fn tenApps(ix: *Index) !void {
    for ([_][]const u8{ "Safari", "Mail", "Maps", "Music", "Notes", "Numbers", "Pages", "Photos", "Calendar", "Calculator" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
}

fn fullList(t: *ui.Tester, s: *view.Nanolight) void {
    tests.press(t, &.{.{ .insert = "a" }});
    var four: suggest.List = .{};
    for ([_][]const u8{ "a1", "a2", "a3", "a4" }) |w| four.push(w);
    s.answered("a", &four);
    t.frame();
}

test "the panel keeps one height, and a long list shows whole rows" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try tenApps(&ix);
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.host.?.resize = struct {
        fn f(_: *anyopaque, _: f32) void {}
    }.f;
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer t.deinit();
    t.settle(1);
    try std.testing.expectEqual(view.rows_height, s.last_h);
    tests.press(&t, &.{.{ .insert = "2+2" }});
    try std.testing.expectEqual(view.rows_height, s.last_h);
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    fullList(&t, &s);
    try std.testing.expectEqual(view.rows_height, s.last_h);
    const last = "Search X for “a”";
    const fold = view.rows_height - view.footer_h;
    // Below the fold it isn't drawn at all, rather than cut in half.
    try std.testing.expect(!t.hasText(last));
    while (s.sel + 1 < s.res.n) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.frame();
    const shown = t.findText(last) orelse return error.NoRow;
    try std.testing.expect(shown.y + shown.h <= fold);
    // The wheel looks elsewhere a row at a time, and stays there.
    t.scroll(view.width / 2, 200, 40);
    try std.testing.expect(!t.hasText(last));
    t.settle(1);
    try std.testing.expect(!t.hasText(last));
    // The selection moves, and the list follows it: round to the first row.
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), s.sel);
    try std.testing.expect(!t.hasText(last));
    try std.testing.expect(t.hasText("Applications"));
}

test "a frame shows the state it was built for: nothing is on its way" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try tenApps(&ix);
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.rows_height, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    fullList(&t, &s);
    const steps = [_]enum { down, wheel_down, wheel_up, typed, answer, up }{ .down, .wheel_down, .wheel_up, .typed, .answer, .up };
    for (steps) |step| {
        switch (step) {
            .down => {
                for (0..8) |_| _ = t.shortcut(.{ .key = ui.Shortcut.down });
            },
            .up => _ = t.shortcut(.{ .key = ui.Shortcut.up }),
            .wheel_down => t.scroll(view.width / 2, 200, -40),
            .wheel_up => t.scroll(view.width / 2, 200, 40),
            .typed => t.textOps(&.{.{ .insert = "b" }}),
            .answer => {
                var said: suggest.List = .{};
                for ([_][]const u8{ "ab1", "ab2" }) |w| said.push(w);
                s.answered("ab", &said);
                t.frame();
            },
        }
        // The frame after the change, against one well after it: below the
        // field, whose caret blinks, they are the same pixels.
        try std.testing.expect(!t.ctx.animating);
        const now = try t.render(gpa);
        defer now.deinit(gpa);
        t.advance(2);
        const later = try t.render(gpa);
        defer later.deinit(gpa);
        const from = @as(usize, view.header_h + 1) * now.width * 4;
        try std.testing.expectEqualSlices(u8, later.bytes[from..], now.bytes[from..]);
    }
}

test "Google's last rows hold their places until it answers" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer t.deinit();
    t.settle(1);
    tests.press(&t, &.{.{ .insert = "liq" }});
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid", "liquid glass" }) |w| said.push(w);
    s.answered("liq", &said);
    t.frame();
    const grok = (t.findText("Ask Grok “liq”") orelse return error.NoRow).y;
    // A letter neither begins with: asked about, and nothing below moves.
    tests.press(&t, &.{.{ .insert = "x" }});
    try std.testing.expectEqualStrings("liqx", web.asked[0..web.asked_len]);
    try std.testing.expect(t.hasText("liquid glass"));
    try std.testing.expectEqual(grok, (t.findText("Ask Grok “liqx”") orelse return error.NoRow).y);
    // The answer replaces them.
    var more: suggest.List = .{};
    for ([_][]const u8{ "liqxa", "liqxb" }) |w| more.push(w);
    s.answered("liqx", &more);
    t.frame();
    try std.testing.expect(!t.hasText("liquid glass"));
    try std.testing.expectEqual(grok, (t.findText("Ask Grok “liqx”") orelse return error.NoRow).y);
    // Words that are never asked about keep no rows.
    tests.press(&t, &.{.{ .insert = ".org" }});
    try std.testing.expectEqual(@as(usize, 0), s.web.n);
}

test "Ask Claude is off until Settings turns it on, and stays as it was left" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var mem: nanoui.kv.Memory = .{ .gpa = gpa };
    defer mem.deinit();
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix, .kv = mem.store() };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(!settings_view.loadClaude(mem.store(), gpa));

    tests.press(&t, &.{.{ .insert = "liquid glass" }});
    try std.testing.expect(!t.containsText("Ask Claude"));

    // On: the row is there at once, and goes where Grok's does.
    s.openSettings();
    t.settle(1);
    try t.clickText("Ask Claude");
    t.settle(1);
    // The switch and everything under it fit Settings, on every platform.
    const quit = t.findText("Back").?;
    try std.testing.expect(quit.y + quit.h <= settings_view.height);
    try std.testing.expect(settings_view.height <= view.max_height);
    try std.testing.expect(s.claude_on and settings_view.loadClaude(mem.store(), gpa));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try std.testing.expect(t.containsText("Ask Claude"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://claude.ai/new?q=liquid+glass", web.probe.opened[0..web.probe.opened_len]);

    // Off again: gone, the selection still on a row that exists.
    s.reveal();
    s.openSettings();
    t.settle(1);
    try t.clickText("Ask Claude");
    t.settle(1);
    try std.testing.expect(!s.claude_on and !settings_view.loadClaude(mem.store(), gpa));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try std.testing.expect(!t.containsText("Ask Claude"));
    try std.testing.expect(s.sel < s.res.n);
}

test "Clipboard History is a Settings switch: off clears what it holds, and the choice is saved" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var mem: nanoui.kv.Memory = .{ .gpa = gpa };
    defer mem.deinit();
    var web: tests.Web = .{};
    var hist: clipboard.History = .{ .gpa = gpa };
    defer hist.deinit();
    try hist.push("copied");
    var s: view.Nanolight = .{ .index = &ix, .kv = mem.store(), .history = &hist };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    s.openSettings();
    t.settle(1);
    try std.testing.expect(hist.on);
    // The row's there, and the footer stays inside the panel.
    const back = t.findText("Back").?;
    try std.testing.expect(back.y + back.h <= settings_view.height);
    try std.testing.expect(settings_view.height <= view.max_height);
    // ↓ to the last row scrolls it into view; the footer hasn't moved.
    while (!t.containsText("Quit Nanolight")) {
        _ = t.shortcut(.{ .key = ui.Shortcut.down });
        t.settle(1);
        try std.testing.expect(s.settings_ui.sel < 20);
    }
    try std.testing.expectEqual(back.y, t.findText("Back").?.y);
    const quit = t.findText("Quit Nanolight").?;
    try std.testing.expect(quit.y + quit.h <= back.y);
    // ↑ to the first row brings it back, and the Terms line scrolls to itself.
    while (s.settings_ui.sel > 0) {
        _ = t.shortcut(.{ .key = ui.Shortcut.up });
        t.settle(1);
    }
    try std.testing.expect(t.containsText("Record…"));
    while (!t.containsText("Terms & Privacy") or s.settings_ui.sel < 9) {
        _ = t.shortcut(.{ .key = ui.Shortcut.down });
        t.settle(1);
        try std.testing.expect(s.settings_ui.sel < 20);
    }
    try std.testing.expectEqual(@as(usize, 9), s.settings_ui.sel);
    try t.clickText("Clipboard History");
    t.settle(1);
    try std.testing.expect(!hist.on and hist.items.items.len == 0);
    const v = try mem.store().get(gpa, clipboard.enabled_key);
    defer gpa.free(v.?);
    try std.testing.expectEqualStrings("0", v.?);

    // Without a history (not the Mac's case in the app) there's no row.
    s.history = null;
    s.settings_ui.hide();
    s.openSettings();
    t.settle(1);
    try std.testing.expect(!t.containsText("Clipboard History"));
}

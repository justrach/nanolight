//! Integration and security tests for browse <-> Nanolight companion behavior.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const results = @import("results.zig");
const settings_view = @import("settings_view.zig");
const browse = @import("browse.zig");
const browse_install = @import("browse_install.zig");
const tests = @import("tests.zig");

const mac = builtin.os.tag == .macos;

fn selectKind(t: *ui.Tester, s: *view.Nanolight, target: results.Kind) !void {
    for (0..s.res.n) |_| {
        if (s.res.rows[s.sel].kind == target) return;
        _ = t.shortcut(.{ .key = ui.Shortcut.down });
    }
    return error.RowKindNotFound;
}

const InstallProbe = struct {
    web: tests.Web = .{},
    installs: usize = 0,
    use_browse_calls: usize = 0,
    last_use_browse: ?bool = null,
    browse_installed: bool = false,
    box: @import("settings_host.zig").SettingsHost = undefined,
    prefs: tests.Prefs = .{},

    fn init(p: *InstallProbe) void {
        p.prefs.init();
        p.box = p.prefs.box;
        p.box.ctx = p;
        // Forward base Prefs hooks cleanly while tracking browse-specific actions.
        p.box.choice = choiceFwd;
        p.box.apply = applyFwd;
        p.box.record = recordFwd;
        p.box.login = loginFwd;
        p.box.suggest = suggestFwd;
        p.box.searches_out = searchesOutFwd;
        p.box.theme = themeFwd;
        p.box.menu_bar = menuBarFwd;
        p.box.account = acctFwd;
        p.box.email = emailFwd;
        p.box.sign_in = noop;
        p.box.sign_out = noop;
        p.box.terms = noop;
        p.box.version = verFwd;
        p.box.ready = readyFwd;
        p.box.check = noop;
        p.box.restart = noop;
        p.box.welcome = noop;
        p.box.quit = noop;
        p.box.use_browse = useBrowse;
        p.box.browse_installed = browseInstalled;
        p.box.browse_busy = browseBusy;
        p.box.browse_status = browseStatus;
        p.box.install_browse = installBrowse;
    }

    fn host(p: *InstallProbe) view.Host {
        var h = p.web.host();
        h.install_browse = installBrowse;
        h.settings = &p.box;
        return h;
    }

    fn self(ctx: *anyopaque) *InstallProbe {
        return @ptrCast(@alignCast(ctx));
    }
    fn prefsPtr(ctx: *anyopaque) *tests.Prefs {
        return &self(ctx).prefs;
    }
    fn choiceFwd(ctx: *anyopaque) @import("shortcut.zig").Choice {
        return prefsPtr(ctx).box.choice(prefsPtr(ctx));
    }
    fn applyFwd(ctx: *anyopaque, c: @import("shortcut.zig").Choice) void {
        prefsPtr(ctx).box.apply(prefsPtr(ctx), c);
    }
    fn recordFwd(ctx: *anyopaque, on: bool) void {
        prefsPtr(ctx).box.record(prefsPtr(ctx), on);
    }
    fn loginFwd(ctx: *anyopaque, set: ?bool) bool {
        return prefsPtr(ctx).box.login(prefsPtr(ctx), set);
    }
    fn suggestFwd(ctx: *anyopaque, on: bool) void {
        prefsPtr(ctx).box.suggest(prefsPtr(ctx), on);
    }
    fn searchesOutFwd(ctx: *anyopaque, on: bool) void {
        prefsPtr(ctx).box.searches_out(prefsPtr(ctx), on);
    }
    fn themeFwd(ctx: *anyopaque, t_val: @import("palette.zig").Theme) void {
        prefsPtr(ctx).box.theme(prefsPtr(ctx), t_val);
    }
    fn menuBarFwd(ctx: *anyopaque, set: ?bool) bool {
        return prefsPtr(ctx).box.menu_bar(prefsPtr(ctx), set);
    }
    fn acctFwd(ctx: *anyopaque) @import("account.zig").State {
        return prefsPtr(ctx).box.account(prefsPtr(ctx));
    }
    fn emailFwd(ctx: *anyopaque) []const u8 {
        return prefsPtr(ctx).box.email(prefsPtr(ctx));
    }
    fn verFwd(ctx: *anyopaque) []const u8 {
        return prefsPtr(ctx).box.version(prefsPtr(ctx));
    }
    fn readyFwd(ctx: *anyopaque) ?[]const u8 {
        return prefsPtr(ctx).box.ready(prefsPtr(ctx));
    }
    fn noop(_: *anyopaque) void {}

    fn useBrowse(ctx: *anyopaque, on: bool) void {
        const p = self(ctx);
        p.use_browse_calls += 1;
        p.last_use_browse = on;
    }
    fn browseInstalled(ctx: *anyopaque) bool {
        return self(ctx).browse_installed;
    }
    fn browseBusy(_: *anyopaque) bool {
        return false;
    }
    fn browseStatus(_: *anyopaque, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "Install browse", .{}) catch "Install browse";
    }
    fn installBrowse(ctx: *anyopaque) void {
        self(ctx).installs += 1;
    }
};

const sample_snapshot =
    \\{
    \\  "version": 1,
    \\  "updatedAt": 1732500000,
    \\  "tabs": [
    \\    {
    \\      "id": "11111111-1111-1111-1111-111111111111",
    \\      "title": "Swift Package Registry Docs",
    \\      "url": "https://swift.org/packages",
    \\      "host": "swift.org",
    \\      "spaceId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    \\      "spaceName": "Engineering",
    \\      "group": "Docs",
    \\      "pinned": false,
    \\      "active": true
    \\    },
    \\    {
    \\      "id": "22222222-2222-2222-2222-222222222222",
    \\      "title": "Bad Javascript Tab",
    \\      "url": "javascript:alert(1)",
    \\      "host": "",
    \\      "spaceId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    \\      "spaceName": "Engineering",
    \\      "group": "",
    \\      "pinned": false,
    \\      "active": false
    \\    }
    \\  ],
    \\  "bookmarks": [
    \\    {
    \\      "title": "Swift Packages Mirror",
    \\      "url": "https://swift.org/packages",
    \\      "host": "swift.org",
    \\      "folder": "Dev"
    \\    },
    \\    {
    \\      "title": "Zig Language Reference",
    \\      "url": "https://ziglang.org/documentation/master/",
    \\      "host": "ziglang.org",
    \\      "folder": "Systems"
    \\    }
    \\  ],
    \\  "spaces": [
    \\    { "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "name": "Engineering" }
    \\  ],
    \\  "shortcuts": [
    \\    { "keyword": "gh", "name": "GitHub Issues", "template": "https://github.com/search?type=issues&q=%s" },
    \\    { "keyword": "evil", "name": "Bad Scheme", "template": "file:///etc/passwd?%s" }
    \\  ]
    \\}
;

test "browse.Index decodes launcher.json, filters unsafe URLs, deduplicates and ranks" {
    const t = std.testing;
    var ix: browse.Index = .init(t.allocator);
    defer ix.deinit();

    try ix.loadBytes(sample_snapshot);
    try t.expectEqual(@as(usize, 1), ix.tabs.len);
    try t.expectEqualStrings("Swift Package Registry Docs", ix.tabs[0].title);
    try t.expectEqual(@as(usize, 2), ix.bookmarks.len);
    try t.expectEqual(@as(usize, 1), ix.shortcuts.len);
    try t.expectEqualStrings("gh", ix.shortcuts[0].keyword);

    // Tab deduplicates identical-URL bookmark ("https://swift.org/packages").
    var hits: [browse.max_hits]browse.Hit = undefined;
    const nh = browse.rank(&ix, "swift", &hits);
    try t.expectEqual(@as(usize, 1), nh);
    try t.expectEqual(browse.HitKind.tab, hits[0].kind);

    // Bookmark not open as a tab still ranks.
    const nb = browse.rank(&ix, "ziglang", &hits);
    try t.expectEqual(@as(usize, 1), nb);
    try t.expectEqual(browse.HitKind.bookmark, hits[0].kind);

    // Custom shortcut overrides built-in `!gh`, while built-in `!yt` still works.
    const m_gh = browse.resolveBang(&ix, "!gh memory leak").?;
    try t.expectEqualStrings("GitHub Issues", m_gh.shortcut.name);
    var ubuf: [browse.max_url_len]u8 = undefined;
    const expanded = browse.bangTargetUrl(&ubuf, m_gh);
    try t.expectEqualStrings("https://github.com/search?type=issues&q=memory%20leak", expanded);

    const m_yt = browse.resolveBang(&ix, "!yt lofi beats").?;
    try t.expectEqualStrings("YouTube", m_yt.shortcut.name);

    // Malformed JSON does not leak or crash.
    try t.expectError(error.SyntaxError, ix.loadBytes("{not valid json"));
    try t.expectEqual(@as(usize, 1), ix.tabs.len);
}

test "browse.Index reloadIfChanged tracks file updates and clears cleanly when missing" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.json", .data = sample_snapshot });
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "b.json",
        .data = "{\"version\":1,\"tabs\":[],\"bookmarks\":[{\"title\":\"Only BM\",\"url\":\"https://example.com\",\"host\":\"example.com\"}]}",
    });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &root_buf);
    const root = root_buf[0..n];

    var pa_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pa = try std.fmt.bufPrint(&pa_buf, "{s}/a.json", .{root});
    var pb_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pb = try std.fmt.bufPrint(&pb_buf, "{s}/b.json", .{root});
    var missing_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pm = try std.fmt.bufPrint(&missing_buf, "{s}/missing.json", .{root});

    var ix: browse.Index = .init(t.allocator);
    defer ix.deinit();

    ix.reloadIfChanged(t.io, pa);
    try t.expect(ix.loaded);
    try t.expectEqual(@as(usize, 1), ix.tabs.len);

    // Second call with same path & unchanged mtime keeps data intact.
    ix.reloadIfChanged(t.io, pa);
    try t.expectEqual(@as(usize, 1), ix.tabs.len);

    // Different snapshot reloads cleanly.
    ix.reloadIfChanged(t.io, pb);
    try t.expectEqual(@as(usize, 0), ix.tabs.len);
    try t.expectEqual(@as(usize, 1), ix.bookmarks.len);

    // Missing file clears index.
    ix.reloadIfChanged(t.io, pm);
    try t.expect(!ix.loaded);
}

test "browse.detectInRoots locates browse.app bundle and wantsInstallRow guards false positives" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &root_buf);
    const root = root_buf[0..n];

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    try t.expect(browse.detectInRoots(t.io, &.{root}, &out_buf) == null);

    try tmp.dir.createDirPath(t.io, "browse.app/Contents");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "browse.app/Contents/Info.plist", .data = "<plist/>" });

    const found = browse.detectInRoots(t.io, &.{root}, &out_buf).?;
    var exp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected = try std.fmt.bufPrint(&exp_buf, "{s}/browse.app", .{root});
    try t.expectEqualStrings(expected, found);

    // Install prompt matching is narrow and disabled once installed.
    try t.expect(browse.wantsInstallRow("browse", false));
    try t.expect(browse.wantsInstallRow("install browse", false));
    try t.expect(browse.wantsInstallRow("codegraff", false));
    try t.expect(!browse.wantsInstallRow("install", false));
    try t.expect(!browse.wantsInstallRow("download", false));
    try t.expect(!browse.wantsInstallRow("br", false));
    try t.expect(!browse.wantsInstallRow("browse", true));
}

test "browse URL command builders percent-encode safely" {
    const t = std.testing;
    var buf: [browse.max_url_len]u8 = undefined;
    try t.expectEqualStrings(
        "browse://open?url=https%3A%2F%2Fexample.com%2Fsearch%3Fq%3Da%20b",
        browse.openUrl(&buf, "https://example.com/search?q=a b"),
    );
    try t.expectEqualStrings("browse://tab?id=abc-123", browse.tabUrl(&buf, "abc-123"));
    try t.expectEqualStrings("browse://ask?q=how%20does%20this%20work%3F", browse.askUrl(&buf, "how does this work?"));
    try t.expectEqualStrings("browse://search?q=hello%20world", browse.searchUrl(&buf, "hello world"));
}

test "browse_install validates appcast, SHA-256, and strict Developer ID codesign identity" {
    const t = std.testing;
    const valid_json =
        \\{
        \\  "version": "1.13.0",
        \\  "build": 202611250412,
        \\  "url": "https://github.com/justrach/browse/releases/download/v1.13.0/browse.zip",
        \\  "sha256": "95939caabc5b46d552f7e4547ea3d2bf2cffacf091489e775c6a864010eb012c"
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cast = try browse_install.parseAppcast(arena.allocator(), valid_json);
    try t.expectEqualStrings("1.13.0", cast.version);

    // Reject HTTP, untrusted host, non-zip, or invalid SHA.
    try t.expectError(error.InvalidAppcast, browse_install.parseAppcast(
        arena.allocator(),
        \\{"version":"1.13.0","url":"http://github.com/justrach/browse/releases/download/v1.13.0/browse.zip","sha256":"95939caabc5b46d552f7e4547ea3d2bf2cffacf091489e775c6a864010eb012c"}
    ));
    try t.expectError(error.InvalidAppcast, browse_install.parseAppcast(
        arena.allocator(),
        \\{"version":"1.13.0","url":"https://evil.example.com/browse.zip","sha256":"95939caabc5b46d552f7e4547ea3d2bf2cffacf091489e775c6a864010eb012c"}
    ));
    try t.expectError(error.InvalidAppcast, browse_install.parseAppcast(
        arena.allocator(),
        \\{"version":"1.13.0","url":"https://github.com/justrach/browse/releases/download/v1.13.0/browse.zip","sha256":"bad"}
    ));

    // SHA-256 verification on known input ("abc").
    const abc_sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try t.expect(browse_install.verifySha256("abc", abc_sha));
    try t.expect(!browse_install.verifySha256("abd", abc_sha));

    const good_cs =
        \\Identifier=com.codegraff.search
        \\Authority=Developer ID Application: Rachit Pradhan (WWP9DLJ27P)
        \\TeamIdentifier=WWP9DLJ27P
    ;
    try t.expect(browse_install.validCodesign(browse_install.parseCodesignOutput(good_cs)));

    const wrong_team =
        \\Identifier=com.codegraff.search
        \\Authority=Developer ID Application: Someone Else (AAAAAAAAAA)
        \\TeamIdentifier=AAAAAAAAAA
    ;
    try t.expect(!browse_install.validCodesign(browse_install.parseCodesignOutput(wrong_team)));

    const adhoc_no_devid =
        \\Identifier=com.codegraff.search
        \\TeamIdentifier=WWP9DLJ27P
    ;
    try t.expect(!browse_install.validCodesign(browse_install.parseCodesignOutput(adhoc_no_devid)));
}

test "Nanolight keeps native preview on Return and routes web actions through browse when active" {
    const gpa = std.testing.allocator;
    var app_ix: Index = .init(gpa);
    defer app_ix.deinit();
    var b_ix: browse.Index = .init(gpa);
    defer b_ix.deinit();
    try b_ix.loadBytes(sample_snapshot);

    var web: tests.Web = .{};
    var s: view.Nanolight = .{
        .index = &app_ix,
        .browse_index = &b_ix,
        .browse_installed = true,
        .browse_on = true,
    };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);

    // 1. Return on Google Search still opens Nanolight's native inline preview, showing "Open in browse".
    tests.press(&t, &.{.{ .insert = "liquid glass" }});
    try selectKind(&t, &s, .search_web);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expect(s.previewing);
    try std.testing.expect(web.page_len != null);
    try std.testing.expect(t.containsText("Open in browse"));

    // 2. ⌘↩ opens Google search through `browse://open?url=...`.
    s.back();
    try selectKind(&t, &s, .search_web);
    _ = t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true });
    const out_url = web.probe.opened[0..web.probe.opened_len];
    try std.testing.expect(std.mem.startsWith(u8, out_url, "browse://open?url=https%3A%2F%2Fwww.google.com%2Fsearch%3Fq%3Dliquid%2Bglass"));

    // 3. Matching open tab routes to `browse://tab?id=...`.
    web.probe = .{};
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "swift package" } });
    try selectKind(&t, &s, .browse_tab);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("browse://tab?id=11111111-1111-1111-1111-111111111111", web.probe.opened[0..web.probe.opened_len]);

    // 4. `!gh memory` expands custom shortcut and opens via `browse://open?url=...`.
    web.probe = .{};
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "!gh memory" } });
    try std.testing.expectEqual(results.Kind.browse_bang, s.res.rows[0].kind);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings(
        "browse://open?url=https%3A%2F%2Fgithub.com%2Fsearch%3Ftype%3Dissues%26q%3Dmemory",
        web.probe.opened[0..web.probe.opened_len],
    );

    // 5. Ask Codegraff routes to `browse://ask?q=...`.
    web.probe = .{};
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "summarize swift" } });
    try selectKind(&t, &s, .ask_browse);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("browse://ask?q=summarize%20swift", web.probe.opened[0..web.probe.opened_len]);

    // 6. Toggling Use browse off falls back cleanly to standard browser URLs and label.
    s.browse_on = false;
    s.built = 1;
    t.settle(1);
    web.probe = .{};
    try selectKind(&t, &s, .ask_grok);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://grok.com/?q=summarize+swift", web.probe.opened[0..web.probe.opened_len]);

    try selectKind(&t, &s, .search_web);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expect(s.previewing);
    try std.testing.expect(t.containsText("Open in Browser"));
}

test "Nanolight offers smooth Install browse flow and fits Settings within max_height" {
    const gpa = std.testing.allocator;
    var app_ix: Index = .init(gpa);
    defer app_ix.deinit();

    var probe: InstallProbe = .{};
    probe.init();
    var installer: browse_install.State = .{};

    var s: view.Nanolight = .{
        .index = &app_ix,
        .browse_installed = false,
        .browse_installer = &installer,
    };
    defer s.query.deinit();
    s.host = probe.host();
    s.reveal();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);

    // Typing "install browse" shows Install CTA at row 0 and keeps panel open when activated.
    tests.press(&t, &.{.{ .insert = "install browse" }});
    try std.testing.expectEqual(results.Kind.install_browse, s.res.rows[0].kind);
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqual(@as(usize, 1), probe.installs);
    try std.testing.expect(!probe.web.probe.hidden);

    // Settings renders Install browse button cleanly and Quit Nanolight stays inside panel bounds.
    s.openSettings();
    t.settle(1);
    const quit = t.findText("Quit Nanolight").?;
    try std.testing.expect(quit.y + quit.h <= settings_view.height);
    try std.testing.expect(settings_view.height <= view.max_height);

    if (comptime mac) {
        try t.clickText("Install browse");
        t.settle(1);
        try std.testing.expectEqual(@as(usize, 2), probe.installs);

        // Once installed, Settings switches to "Use browse" toggle and persists changes.
        probe.browse_installed = true;
        s.browse_installed = true;
        t.settle(1);
        try t.clickText("Use browse");
        t.settle(1);
        try std.testing.expect(!s.browse_on);
        try std.testing.expectEqual(@as(usize, 1), probe.use_browse_calls);
        try std.testing.expectEqual(@as(?bool, false), probe.last_use_browse);
        const quit2 = t.findText("Quit Nanolight").?;
        try std.testing.expect(quit2.y + quit2.h <= settings_view.height);
    }
}

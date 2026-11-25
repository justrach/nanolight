//! Live's answers to Settings. The box is one, its context set to the
//! Live that is showing the panel (one Nanolight runs).
const nanoui = @import("nanoui");
const shortcut = @import("shortcut.zig");
const account = @import("account.zig");
const browse = @import("browse.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Theme = @import("palette.zig").Theme;
pub var box: SettingsHost = .{
    .ctx = undefined,
    .choice = choice,
    .apply = @import("main.zig").applyChoice,
    .record = @import("main.zig").recordKey,
    .login = @import("main.zig").loginItem,
    .suggest = suggest,
    .searches_out = searchesOut,
    .theme = theme,
    .menu_bar = menuBar,
    .account = acct,
    .email = email,
    .sign_in = signIn,
    .sign_out = signOut,
    .terms = terms,
    .version = version,
    .ready = ready,
    .check = check,
    .restart = restart,
    .welcome = welcome,
    .quit = quit,
    .use_browse = useBrowse,
    .browse_installed = browseInstalled,
    .browse_busy = browseBusy,
    .browse_status = browseStatus,
    .install_browse = installBrowse,
};

const Live = @import("main.zig").Live;

fn l(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn choice(ctx: *anyopaque) shortcut.Choice {
    return l(ctx).choice;
}

fn suggest(ctx: *anyopaque, on: bool) void {
    var item: nanoui.menu.Item = undefined;
    item.checked = on;
    l(ctx).toggleSuggest(&item);
}

fn searchesOut(ctx: *anyopaque, on: bool) void {
    l(ctx).setSearchesOut(on);
}

/// The panel's tint: a `Theme`'s name ("system" when unset).
const theme_key = "nanolight.theme";

fn theme(ctx: *anyopaque, t: Theme) void {
    const live = l(ctx);
    live.s.theme = t;
    live.kv.set(theme_key, @tagName(t)) catch {};
    // The glass's corners and the menu bar icon follow the theme too.
    (if (@import("builtin").os.tag == .macos) @import("panel_mac.zig") else @import("panel_pc.zig")).corners(t.radius());
    if (live.tray) |tray| tray.setSymbol(t.glyph());
    if (live.window) |w| w.redraw();
}

/// What Settings keeps on this machine alone, at launch.
pub fn load(s: *@import("view.zig").Nanolight, kv: nanoui.kv.Store, gpa: @import("std").mem.Allocator) void {
    s.theme = loadTheme(kv, gpa);
    s.claude_on = @import("settings_view.zig").loadClaude(kv, gpa);
    const ub = kv.get(gpa, browse.enabled_key) catch null;
    defer if (ub) |v| gpa.free(v);
    s.browse_on = browse.isEnabled(ub);
}

/// The theme kept on this Mac, at launch.
fn loadTheme(kv: nanoui.kv.Store, gpa: @import("std").mem.Allocator) Theme {
    const v = kv.get(gpa, theme_key) catch null orelse return .system;
    defer gpa.free(v);
    return @import("std").meta.stringToEnum(Theme, v) orelse .system;
}

fn menuBar(ctx: *anyopaque, set: ?bool) bool {
    return l(ctx).menuBar(set);
}

fn acct(ctx: *anyopaque) account.State {
    return if (l(ctx).acct) |*a| a.state else .signed_out;
}

fn email(ctx: *anyopaque) []const u8 {
    return if (l(ctx).acct) |*a| a.email() else "";
}

fn signIn(ctx: *anyopaque) void {
    if (l(ctx).acct) |*a| a.signIn();
}

fn signOut(ctx: *anyopaque) void {
    if (l(ctx).acct) |*a| a.signOut();
}

fn terms(_: *anyopaque) void {
    _ = nanoui.shell.openUrl(account.terms_url);
}

fn version(ctx: *anyopaque) []const u8 {
    const u = l(ctx).updater orelse return "0.1.0";
    return if (u.current.len > 0) u.current else "0.1.0";
}

fn ready(ctx: *anyopaque) ?[]const u8 {
    const u = l(ctx).updater orelse return null;
    return u.ready();
}

fn check(ctx: *anyopaque) void {
    if (l(ctx).updater) |u| u.checkNow();
}

fn restart(ctx: *anyopaque) void {
    const live = l(ctx);
    const u = live.updater orelse return;
    if (u.ready() != null and u.restart()) live.app.quit();
}

fn welcome(ctx: *anyopaque) void {
    const live = l(ctx);
    live.o.start(live.choice);
    if (live.window) |w| if (w.isVisible()) w.redraw();
}

fn quit(ctx: *anyopaque) void {
    l(ctx).app.quit();
}

fn useBrowse(ctx: *anyopaque, on: bool) void {
    l(ctx).setUseBrowse(on);
}

fn browseInstalled(ctx: *anyopaque) bool {
    return l(ctx).s.browse_installed;
}

fn browseBusy(ctx: *anyopaque) bool {
    return l(ctx).browse_installer.busy();
}

fn browseStatus(ctx: *anyopaque, buf: []u8) []const u8 {
    return l(ctx).browse_installer.statusText(buf);
}

fn installBrowse(ctx: *anyopaque) void {
    l(ctx).startInstallBrowse();
}

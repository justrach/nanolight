//! Companion index and command builders for browse (`com.codegraff.search`).
//! Reads the non-sensitive `launcher.json` snapshot written by browse and builds
//! `browse://` deep-link URLs when browse is installed and enabled.

const std = @import("std");
const builtin = @import("builtin");
const search = @import("search.zig");

const mac = builtin.os.tag == .macos;

pub const enabled_key = "useBrowse";
pub const max_hits: usize = 3;
pub const max_index_bytes: usize = 4 << 20;
pub const max_url_len: usize = 4096;

pub const bundle_id = "com.codegraff.search";
pub const team_id = "WWP9DLJ27P";

pub const Tab = struct {
    id: []const u8,
    title: []const u8,
    url: []const u8,
    host: []const u8,
    space_id: []const u8 = "",
    space_name: []const u8 = "",
    group: []const u8 = "",
    pinned: bool = false,
    active: bool = false,
};

pub const Bookmark = struct {
    title: []const u8,
    url: []const u8,
    host: []const u8,
    folder: []const u8 = "",
};

pub const Space = struct {
    id: []const u8,
    name: []const u8,
};

pub const Shortcut = struct {
    keyword: []const u8,
    name: []const u8,
    template: []const u8,
};

pub const HitKind = enum {
    tab,
    bookmark,
};

pub const Hit = struct {
    kind: HitKind,
    index: usize,
    score: i32,
    match: search.Match,
};

pub const BangMatch = struct {
    shortcut: Shortcut,
    terms: []const u8,
};

pub const builtin_shortcuts = [_]Shortcut{
    .{ .keyword = "gh", .name = "GitHub", .template = "https://github.com/search?q=%s" },
    .{ .keyword = "yt", .name = "YouTube", .template = "https://www.youtube.com/results?search_query=%s" },
    .{ .keyword = "mdn", .name = "MDN", .template = "https://developer.mozilla.org/en-US/search?q=%s" },
    .{ .keyword = "w", .name = "Wikipedia", .template = "https://en.wikipedia.org/w/index.php?search=%s" },
    .{ .keyword = "r", .name = "Reddit", .template = "https://www.reddit.com/search/?q=%s" },
    .{ .keyword = "hn", .name = "Hacker News", .template = "https://hn.algolia.com/?q=%s" },
    .{ .keyword = "npm", .name = "npm", .template = "https://www.npmjs.com/search?q=%s" },
    .{ .keyword = "crates", .name = "crates.io", .template = "https://crates.io/search?q=%s" },
    .{ .keyword = "so", .name = "Stack Overflow", .template = "https://stackoverflow.com/search?q=%s" },
    .{ .keyword = "maps", .name = "Google Maps", .template = "https://www.google.com/maps/search/%s" },
    .{ .keyword = "g", .name = "Google", .template = "https://www.google.com/search?q=%s" },
    .{ .keyword = "ddg", .name = "DuckDuckGo", .template = "https://duckduckgo.com/?q=%s" },
    .{ .keyword = "kagi", .name = "Kagi", .template = "https://kagi.com/search?q=%s" },
    .{ .keyword = "apple", .name = "Apple Developer", .template = "https://developer.apple.com/search/?q=%s" },
    .{ .keyword = "pkg", .name = "Swift Package Index", .template = "https://swiftpackageindex.com/search?query=%s" },
};

const JsonTab = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    host: []const u8 = "",
    spaceId: []const u8 = "",
    spaceName: []const u8 = "",
    group: []const u8 = "",
    pinned: bool = false,
    active: bool = false,
};

const JsonBookmark = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    host: []const u8 = "",
    folder: []const u8 = "",
};

const JsonSpace = struct {
    id: []const u8 = "",
    name: []const u8 = "",
};

const JsonShortcut = struct {
    keyword: []const u8 = "",
    name: []const u8 = "",
    template: []const u8 = "",
};

const JsonSnapshot = struct {
    version: i64 = 1,
    tabs: []const JsonTab = &.{},
    bookmarks: []const JsonBookmark = &.{},
    spaces: []const JsonSpace = &.{},
    shortcuts: []const JsonShortcut = &.{},
};

/// Arena-backed companion index decoded from `launcher.json` on demand via mtime check.
pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: ?std.heap.ArenaAllocator = null,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    last_mtime_ns: i128 = -1,
    loaded: bool = false,
    tabs: []const Tab = &.{},
    bookmarks: []const Bookmark = &.{},
    spaces: []const Space = &.{},
    shortcuts: []const Shortcut = &.{},

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ix: *Index) void {
        if (ix.arena) |*a| a.deinit();
        ix.arena = null;
        ix.tabs = &.{};
        ix.bookmarks = &.{};
        ix.spaces = &.{};
        ix.shortcuts = &.{};
        ix.loaded = false;
        ix.last_mtime_ns = -1;
        ix.path_len = 0;
    }

    /// Reloads `launcher.json` only when its path or modification time changes.
    pub fn reloadIfChanged(ix: *Index, io: std.Io, path: []const u8) void {
        if (path.len == 0 or path.len > ix.path_buf.len) {
            ix.clear();
            return;
        }
        var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
            ix.clear();
            return;
        };
        defer file.close(io);

        const st = file.stat(io) catch {
            ix.clear();
            return;
        };
        const mtime_ns = st.mtime.nanoseconds;
        if (ix.loaded and ix.path_len == path.len and std.mem.eql(u8, ix.path_buf[0..ix.path_len], path) and ix.last_mtime_ns == mtime_ns) {
            return;
        }

        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, ix.gpa, .limited(max_index_bytes)) catch {
            ix.clear();
            return;
        };
        defer ix.gpa.free(raw);

        ix.loadBytes(raw) catch {
            ix.clear();
            return;
        };

        @memcpy(ix.path_buf[0..path.len], path);
        ix.path_len = path.len;
        ix.last_mtime_ns = mtime_ns;
        ix.loaded = true;
    }

    /// Decodes a raw `launcher.json` buffer into an isolated arena.
    pub fn loadBytes(ix: *Index, json_bytes: []const u8) !void {
        var next_arena = std.heap.ArenaAllocator.init(ix.gpa);
        errdefer next_arena.deinit();
        const a = next_arena.allocator();

        const snap = try std.json.parseFromSliceLeaky(JsonSnapshot, a, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        var tabs_list: std.ArrayList(Tab) = .empty;
        for (snap.tabs) |item| {
            if (!isHttpUrl(item.url) or item.id.len == 0) continue;
            try tabs_list.append(a, .{
                .id = item.id,
                .title = if (item.title.len > 0) item.title else item.host,
                .url = item.url,
                .host = item.host,
                .space_id = item.spaceId,
                .space_name = item.spaceName,
                .group = item.group,
                .pinned = item.pinned,
                .active = item.active,
            });
        }

        var bms_list: std.ArrayList(Bookmark) = .empty;
        for (snap.bookmarks) |item| {
            if (!isHttpUrl(item.url)) continue;
            try bms_list.append(a, .{
                .title = if (item.title.len > 0) item.title else item.host,
                .url = item.url,
                .host = item.host,
                .folder = item.folder,
            });
        }

        var spaces_list: std.ArrayList(Space) = .empty;
        for (snap.spaces) |item| {
            if (item.id.len == 0 or item.name.len == 0) continue;
            try spaces_list.append(a, .{ .id = item.id, .name = item.name });
        }

        var cuts_list: std.ArrayList(Shortcut) = .empty;
        for (snap.shortcuts) |item| {
            if (item.keyword.len == 0 or item.template.len == 0) continue;
            if (!isHttpUrl(item.template)) continue;
            try cuts_list.append(a, .{
                .keyword = item.keyword,
                .name = if (item.name.len > 0) item.name else item.keyword,
                .template = item.template,
            });
        }

        if (ix.arena) |*old| old.deinit();
        ix.arena = next_arena;
        ix.tabs = tabs_list.items;
        ix.bookmarks = bms_list.items;
        ix.spaces = spaces_list.items;
        ix.shortcuts = cuts_list.items;
        ix.loaded = true;
    }

    pub fn clear(ix: *Index) void {
        if (!ix.loaded and ix.arena == null) return;
        ix.deinit();
    }
};

/// Resolves the macOS default `launcher.json` path under `$HOME/Library/Application Support/browse/`.
pub fn defaultIndexPath(env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    if (!mac) return null;
    const e = env orelse return null;
    const home = e.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/browse/launcher.json", .{home}) catch null;
}

/// Checks `/Applications/browse.app` and `$HOME/Applications/browse.app` on macOS.
pub fn detectInstalledPath(io: std.Io, env: ?*const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    if (!mac) return null;
    const home = if (env) |e| e.get("HOME") else null;
    var roots_buf: [2][]const u8 = undefined;
    var n: usize = 0;
    roots_buf[n] = "/Applications";
    n += 1;
    var home_apps_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (home) |h| {
        if (std.fmt.bufPrint(&home_apps_buf, "{s}/Applications", .{h})) |ha| {
            roots_buf[n] = ha;
            n += 1;
        } else |_| {}
    }
    return detectInRoots(io, roots_buf[0..n], buf);
}

/// Probes explicit application parent folders for a valid `browse.app` bundle.
pub fn detectInRoots(io: std.Io, roots: []const []const u8, buf: []u8) ?[]const u8 {
    var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (roots) |root| {
        if (root.len == 0) continue;
        const clean_root = std.mem.trimEnd(u8, root, "/");
        const plist = std.fmt.bufPrint(&probe_buf, "{s}/browse.app/Contents/Info.plist", .{clean_root}) catch continue;
        std.Io.Dir.accessAbsolute(io, plist, .{}) catch continue;
        return std.fmt.bufPrint(buf, "{s}/browse.app", .{clean_root}) catch null;
    }
    return null;
}

/// Ranks matching tabs and bookmarks from `ix` for `query` into `out` (tabs deduplicate bookmarks).
pub fn rank(ix: *const Index, query_in: []const u8, out: []Hit) usize {
    const query = std.mem.trim(u8, query_in, " ");
    if (query.len == 0 or query[0] == '!' or out.len == 0) return 0;

    const max_cand = 64;
    var cands: [max_cand]Hit = undefined;
    var nc: usize = 0;

    for (ix.tabs, 0..) |tab, i| {
        const hit = scoreTab(query, tab) orelse continue;
        insertCandidate(&cands, &nc, .{
            .kind = .tab,
            .index = i,
            .score = hit.score,
            .match = hit.match,
        });
    }

    for (ix.bookmarks, 0..) |bm, i| {
        if (hasTabUrl(ix.tabs, &cands, nc, bm.url)) continue;
        const hit = scoreBookmark(query, bm) orelse continue;
        insertCandidate(&cands, &nc, .{
            .kind = .bookmark,
            .index = i,
            .score = hit.score,
            .match = hit.match,
        });
    }

    const n = @min(nc, out.len);
    @memcpy(out[0..n], cands[0..n]);
    return n;
}

/// Matches `!bang` prefixes against custom shortcuts from `launcher.json` first, then built-ins.
pub fn resolveBang(ix: *const Index, query_in: []const u8) ?BangMatch {
    const q = std.mem.trim(u8, query_in, " \t\r\n");
    if (q.len < 2 or q[0] != '!') return null;
    const after_bang = q[1..];
    const space_at = std.mem.indexOfAny(u8, after_bang, " \t") orelse after_bang.len;
    const kw = after_bang[0..space_at];
    if (kw.len == 0) return null;
    const terms = if (space_at < after_bang.len)
        std.mem.trim(u8, after_bang[space_at + 1 ..], " \t\r\n")
    else
        "";

    for (ix.shortcuts) |sc| {
        if (std.ascii.eqlIgnoreCase(sc.keyword, kw)) {
            return .{ .shortcut = sc, .terms = terms };
        }
    }
    for (builtin_shortcuts) |sc| {
        if (std.ascii.eqlIgnoreCase(sc.keyword, kw)) {
            return .{ .shortcut = sc, .terms = terms };
        }
    }
    return null;
}

/// Expands a `Shortcut.template` (`%s`) into a normalized `http(s)://` target URL.
pub fn bangTargetUrl(buf: []u8, match: BangMatch) []const u8 {
    var enc_buf: [1024]u8 = undefined;
    const enc = percentEncode(&enc_buf, match.terms);
    if (std.mem.indexOf(u8, match.shortcut.template, "%s")) |pos| {
        const pre = match.shortcut.template[0..pos];
        const post = match.shortcut.template[pos + 2 ..];
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ pre, enc, post }) catch "";
    }
    if (match.terms.len == 0) return match.shortcut.template;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ match.shortcut.template, enc }) catch "";
}

/// Returns true when the query explicitly asks for browse while browse is not yet installed.
pub fn wantsInstallRow(query_in: []const u8, installed: bool) bool {
    if (installed) return false;
    const q = std.mem.trim(u8, query_in, " \t\r\n");
    if (q.len < 4) return false;
    if (std.ascii.startsWithIgnoreCase("browse", q)) return true;
    if (q.len >= 5 and std.ascii.startsWithIgnoreCase("codegraff", q)) return true;
    return containsAsciiFold(q, "browse");
}

fn containsAsciiFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Reads the persistent `useBrowse` preference; defaults on when browse is installed.
pub fn isEnabled(raw: ?[]const u8) bool {
    const v = raw orelse return true;
    return !std.mem.eql(u8, v, "0");
}

pub fn isHttpUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}

/// Builds `browse://open?url=<encoded>`. Pass plain `target` through unchanged if already `browse://`.
pub fn openUrl(buf: []u8, target: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(target, "browse://")) return target;
    var enc_buf: [4096]u8 = undefined;
    const enc = percentEncode(&enc_buf, target);
    return std.fmt.bufPrint(buf, "browse://open?url={s}", .{enc}) catch target;
}

/// Builds `browse://tab?id=<uuid>`.
pub fn tabUrl(buf: []u8, tab_id: []const u8) []const u8 {
    var enc_buf: [256]u8 = undefined;
    const enc = percentEncode(&enc_buf, tab_id);
    return std.fmt.bufPrint(buf, "browse://tab?id={s}", .{enc}) catch "";
}

/// Builds `browse://space?id=<uuid>&name=<name>`.
pub fn spaceUrl(buf: []u8, space_id: []const u8, name: []const u8) []const u8 {
    var id_buf: [256]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    const eid = percentEncode(&id_buf, space_id);
    const ename = percentEncode(&name_buf, name);
    return std.fmt.bufPrint(buf, "browse://space?id={s}&name={s}", .{ eid, ename }) catch "";
}

/// Builds `browse://ask?q=<encoded>` (prefills Agent draft in browse without auto-sending).
pub fn askUrl(buf: []u8, prompt: []const u8) []const u8 {
    var enc_buf: [4096]u8 = undefined;
    const enc = percentEncode(&enc_buf, prompt);
    return std.fmt.bufPrint(buf, "browse://ask?q={s}", .{enc}) catch "";
}

/// Builds `browse://search?q=<encoded>`.
pub fn searchUrl(buf: []u8, query: []const u8) []const u8 {
    var enc_buf: [4096]u8 = undefined;
    const enc = percentEncode(&enc_buf, query);
    return std.fmt.bufPrint(buf, "browse://search?q={s}", .{enc}) catch "";
}

/// RFC-3986 percent-encoder safe for query components in `browse://` URLs.
pub fn percentEncode(buf: []u8, raw: []const u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (raw) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            if (n >= buf.len) break;
            buf[n] = c;
            n += 1;
        } else {
            if (n + 3 > buf.len) break;
            buf[n] = '%';
            buf[n + 1] = hex[c >> 4];
            buf[n + 2] = hex[c & 0x0f];
            n += 3;
        }
    }
    return buf[0..n];
}

fn scoreTab(query: []const u8, tab: Tab) ?struct { score: i32, match: search.Match } {
    var best_score: i32 = std.math.minInt(i32);
    var title_match: search.Match = .{ .score = 0 };
    var any = false;

    if (search.score(query, tab.title)) |m| {
        any = true;
        best_score = m.score;
        title_match = m;
    }
    inline for ([_][]const u8{ tab.host, tab.url, tab.space_name, tab.group }) |field| {
        if (search.score(query, field)) |m| {
            any = true;
            if (m.score - 40 > best_score) best_score = m.score - 40;
        }
    }
    if (!any) return null;
    // Open tabs slightly outrank identical bookmarks; active/pinned get a light nudge.
    best_score += 20;
    if (tab.active) best_score += 8;
    if (tab.pinned) best_score += 4;
    return .{ .score = best_score, .match = title_match };
}

fn scoreBookmark(query: []const u8, bm: Bookmark) ?struct { score: i32, match: search.Match } {
    var best_score: i32 = std.math.minInt(i32);
    var title_match: search.Match = .{ .score = 0 };
    var any = false;

    if (search.score(query, bm.title)) |m| {
        any = true;
        best_score = m.score;
        title_match = m;
    }
    inline for ([_][]const u8{ bm.host, bm.url, bm.folder }) |field| {
        if (search.score(query, field)) |m| {
            any = true;
            if (m.score - 40 > best_score) best_score = m.score - 40;
        }
    }
    if (!any) return null;
    return .{ .score = best_score, .match = title_match };
}

fn hasTabUrl(tabs: []const Tab, cands: []const Hit, nc: usize, url: []const u8) bool {
    for (cands[0..nc]) |c| {
        if (c.kind == .tab and std.mem.eql(u8, tabs[c.index].url, url)) return true;
    }
    return false;
}

fn insertCandidate(cands: *[64]Hit, nc: *usize, hit: Hit) void {
    var pos: usize = nc.*;
    while (pos > 0 and hit.score > cands[pos - 1].score) : (pos -= 1) {
        if (pos < cands.len) cands[pos] = cands[pos - 1];
    }
    if (pos < cands.len) {
        cands[pos] = hit;
        if (nc.* < cands.len) nc.* += 1;
    }
}

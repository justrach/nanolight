//! Cryptographically verified in-app installer for browse on macOS.
//! Fetches `appcast.json`, verifies HTTPS release URL, SHA-256 checksum,
//! strict Apple Developer ID signature (`WWP9DLJ27P`, `com.codegraff.search`),
//! and CFBundleShortVersionString match before placing `browse.app`.

const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const browse = @import("browse.zig");

const mac = builtin.os.tag == .macos;

pub const appcast_url = "https://github.com/justrach/browse/releases/latest/download/appcast.json";
pub const download_prefix = "https://github.com/justrach/browse/releases/download/";
pub const team_id = browse.team_id;
pub const bundle_id = browse.bundle_id;
pub const max_zip_bytes: usize = 256 << 20;

pub const Phase = enum(u8) {
    idle,
    fetching,
    downloading,
    verifying,
    installing,
    ready,
    failed,
};

pub const Appcast = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const CodesignInfo = struct {
    team: []const u8 = "",
    id: []const u8 = "",
    has_dev_id_authority: bool = false,
};

const JsonAppcast = struct {
    version: []const u8 = "",
    url: []const u8 = "",
    sha256: []const u8 = "",
};

pub const State = struct {
    phase: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Phase.idle)),
    version_buf: [64]u8 = undefined,
    version_len: usize = 0,
    installed_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    installed_path_len: usize = 0,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,
    progress_ctx: ?*anyopaque = null,
    progress_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn currentPhase(st: *const State) Phase {
        const raw = st.phase.load(.acquire);
        return if (raw <= @intFromEnum(Phase.failed)) @enumFromInt(raw) else .idle;
    }

    pub fn busy(st: *const State) bool {
        return switch (st.currentPhase()) {
            .fetching, .downloading, .verifying, .installing => true,
            else => false,
        };
    }

    pub fn installedPath(st: *const State) []const u8 {
        return st.installed_path_buf[0..st.installed_path_len];
    }

    pub fn statusText(st: *const State, buf: []u8) []const u8 {
        return switch (st.currentPhase()) {
            .idle => "Download & install signed browse",
            .fetching => "Checking latest release…",
            .downloading => "Downloading browse…",
            .verifying => "Verifying signature & SHA-256…",
            .installing => "Installing to Applications…",
            .ready => if (st.version_len > 0)
                std.fmt.bufPrint(buf, "Installed browse v{s}", .{st.version_buf[0..st.version_len]}) catch "Installed browse"
            else
                "Installed browse",
            .failed => if (st.err_len > 0) st.err_buf[0..st.err_len] else "Install failed — Retry",
        };
    }
};

pub const Hooks = struct {
    ctx: *anyopaque,
    on_progress: *const fn (ctx: *anyopaque) void,
    on_done: *const fn (ctx: *anyopaque, ok: bool) void,
};

const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    state: *State,
    hooks: Hooks,
    home: ?[]u8,
    ok: bool = false,
    version_buf: [64]u8 = undefined,
    version_len: usize = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,

    fn setErr(j: *Job, msg: []const u8) void {
        const n = @min(msg.len, j.err_buf.len);
        @memcpy(j.err_buf[0..n], msg[0..n]);
        j.err_len = n;
    }
};

/// Validates `appcast.json`: safe version, HTTPS release download URL, and 64-hex SHA-256.
pub fn parseAppcast(a: std.mem.Allocator, body: []const u8) !Appcast {
    const parsed = try std.json.parseFromSliceLeaky(JsonAppcast, a, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (!validVersion(parsed.version)) return error.InvalidAppcast;
    if (!validDownloadUrl(parsed.url)) return error.InvalidAppcast;
    if (!validHex64(parsed.sha256)) return error.InvalidAppcast;
    return .{
        .version = parsed.version,
        .url = parsed.url,
        .sha256 = parsed.sha256,
    };
}

pub fn verifySha256(bytes: []const u8, expected_hex: []const u8) bool {
    if (!validHex64(expected_hex)) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual_hex = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&actual_hex, expected_hex);
}

/// Extracts `TeamIdentifier`, `Identifier`, and `Authority=Developer ID Application:` from `codesign -dv --verbose=2`.
pub fn parseCodesignOutput(output: []const u8) CodesignInfo {
    var info: CodesignInfo = .{};
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.startsWith(u8, line, "TeamIdentifier=")) {
            info.team = line["TeamIdentifier=".len..];
        } else if (std.mem.startsWith(u8, line, "Identifier=")) {
            info.id = line["Identifier=".len..];
        } else if (std.mem.startsWith(u8, line, "Authority=Developer ID Application:") and std.mem.indexOf(u8, line, "(" ++ team_id ++ ")") != null) {
            info.has_dev_id_authority = true;
        }
    }
    return info;
}

pub fn validCodesign(info: CodesignInfo) bool {
    return info.has_dev_id_authority and std.mem.eql(u8, info.team, team_id) and std.mem.eql(u8, info.id, bundle_id);
}

pub fn validVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 48) return false;
    for (v) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub fn validDownloadUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, download_prefix)) return false;
    if (url.len <= download_prefix.len or url.len > 1024) return false;
    for (url) |c| {
        if (c <= ' ' or c == 0x7f) return false;
    }
    return std.mem.endsWith(u8, url, ".zip");
}

fn validHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Starts a background download, verification, and installation of `browse.app` on macOS.
pub fn start(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    st: *State,
    hooks: Hooks,
) bool {
    if (!mac) return false;
    const prev = st.currentPhase();
    if (prev != .idle and prev != .failed and prev != .ready) return false;
    if (st.phase.cmpxchgStrong(@intFromEnum(prev), @intFromEnum(Phase.fetching), .acq_rel, .acquire) != null) {
        return false;
    }

    const home_slice = if (env) |e| e.get("HOME") else null;
    const home_copy: ?[]u8 = if (home_slice) |h| (gpa.dupe(u8, h) catch null) else null;

    const job = gpa.create(Job) catch {
        if (home_copy) |hc| gpa.free(hc);
        st.phase.store(@intFromEnum(Phase.failed), .release);
        return false;
    };
    job.* = .{
        .gpa = gpa,
        .io = io,
        .state = st,
        .hooks = hooks,
        .home = home_copy,
    };

    st.progress_ctx = hooks.ctx;
    st.progress_fn = hooks.on_progress;

    const t = std.Thread.spawn(.{}, workerMain, .{job}) catch {
        if (job.home) |hc| gpa.free(hc);
        gpa.destroy(job);
        st.phase.store(@intFromEnum(Phase.failed), .release);
        return false;
    };
    t.detach();
    return true;
}

fn workerMain(job: *Job) void {
    if (comptime mac) {
        runInstall(job) catch |err| {
            if (job.err_len == 0) {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Install failed ({s}) — Retry", .{@errorName(err)}) catch "Install failed — Retry";
                job.setErr(msg);
            }
            job.ok = false;
        };
    } else {
        job.setErr("browse installer is macOS-only");
        job.ok = false;
    }
    nanoui.App.after(0, job, finishOnMain);
}

fn finishOnMain(raw: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(raw orelse return));
    defer {
        if (job.home) |hc| job.gpa.free(hc);
        job.gpa.destroy(job);
    }

    const st = job.state;
    if (job.ok) {
        @memcpy(st.version_buf[0..job.version_len], job.version_buf[0..job.version_len]);
        st.version_len = job.version_len;
        @memcpy(st.installed_path_buf[0..job.path_len], job.path_buf[0..job.path_len]);
        st.installed_path_len = job.path_len;
        st.err_len = 0;
        st.phase.store(@intFromEnum(Phase.ready), .release);
    } else {
        @memcpy(st.err_buf[0..job.err_len], job.err_buf[0..job.err_len]);
        st.err_len = job.err_len;
        st.phase.store(@intFromEnum(Phase.failed), .release);
    }
    job.hooks.on_done(job.hooks.ctx, job.ok);
}

fn progressOnMain(raw: ?*anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(raw orelse return));
    if (st.progress_fn) |f| if (st.progress_ctx) |ctx| f(ctx);
}

fn setPhase(j: *Job, phase: Phase) void {
    j.state.phase.store(@intFromEnum(phase), .release);
    nanoui.App.after(0, j.state, progressOnMain);
}

fn runInstall(j: *Job) !void {
    var arena = std.heap.ArenaAllocator.init(j.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Fetch & validate appcast.json
    const appcast_res = try runCmd(a, j.io, &.{
        "/usr/bin/curl",
        "-fsSL",
        "--proto",
        "=https",
        "--tlsv1.2",
        "--connect-timeout",
        "15",
        "--max-time",
        "60",
        appcast_url,
    });
    if (!appcast_res.ok) {
        j.setErr("Could not check latest browse release");
        return error.AppcastFetchFailed;
    }

    const cast = parseAppcast(a, appcast_res.stdout) catch {
        j.setErr("Invalid browse release manifest");
        return error.InvalidAppcast;
    };

    // 2. Private 0700 staging directory created atomically via mktemp -d
    setPhase(j, .downloading);
    const stage_res = try runCmd(a, j.io, &.{ "/usr/bin/mktemp", "-d", "-t", "nanolight-browse" });
    if (!stage_res.ok) {
        j.setErr("Could not create temporary folder");
        return error.StageCreateFailed;
    }
    const stage_dir = std.mem.trim(u8, stage_res.stdout, " \t\r\n");
    if (stage_dir.len == 0) return error.StageCreateFailed;
    defer std.Io.Dir.cwd().deleteTree(j.io, stage_dir) catch {};

    const zip_path = try std.fmt.allocPrint(a, "{s}/browse.zip", .{stage_dir});
    const unpack_dir = try std.fmt.allocPrint(a, "{s}/unpack", .{stage_dir});

    const dl_res = try runCmd(a, j.io, &.{
        "/usr/bin/curl",
        "-fsSL",
        "--proto",
        "=https",
        "--tlsv1.2",
        "--connect-timeout",
        "20",
        "--max-time",
        "300",
        "-o",
        zip_path,
        cast.url,
    });
    if (!dl_res.ok) {
        j.setErr("Failed to download browse archive");
        return error.DownloadFailed;
    }

    // 3. Verify SHA-256, unpack, verify Apple Developer ID Team + Bundle ID + version
    setPhase(j, .verifying);
    const zip_bytes = std.Io.Dir.cwd().readFileAlloc(j.io, zip_path, j.gpa, .limited(max_zip_bytes)) catch {
        j.setErr("Downloaded archive too large or unreadable");
        return error.ZipReadFailed;
    };
    const sha_ok = verifySha256(zip_bytes, cast.sha256);
    j.gpa.free(zip_bytes);
    if (!sha_ok) {
        j.setErr("Checksum verification failed");
        return error.ChecksumMismatch;
    }

    try std.Io.Dir.cwd().createDirPath(j.io, unpack_dir);
    const unzip_res = try runCmd(a, j.io, &.{
        "/usr/bin/ditto",
        "-xk",
        "--sequesterRsrc",
        zip_path,
        unpack_dir,
    });
    if (!unzip_res.ok) {
        j.setErr("Could not unpack browse archive");
        return error.UnpackFailed;
    }

    const unpacked_app = try std.fmt.allocPrint(a, "{s}/browse.app", .{unpack_dir});
    const plist_path = try std.fmt.allocPrint(a, "{s}/Contents/Info.plist", .{unpacked_app});
    std.Io.Dir.accessAbsolute(j.io, plist_path, .{}) catch {
        j.setErr("Archive did not contain browse.app");
        return error.MissingAppBundle;
    };

    const verify_res = try runCmd(a, j.io, &.{
        "/usr/bin/codesign",
        "--verify",
        "--deep",
        "--strict",
        "--verbose=2",
        unpacked_app,
    });
    if (!verify_res.ok) {
        j.setErr("browse signature verification failed");
        return error.CodesignVerifyFailed;
    }

    const info_res = try runCmd(a, j.io, &.{
        "/usr/bin/codesign",
        "-dv",
        "--verbose=2",
        unpacked_app,
    });
    const combined_info = if (info_res.stderr.len > 0) info_res.stderr else info_res.stdout;
    if (!info_res.ok or !validCodesign(parseCodesignOutput(combined_info))) {
        j.setErr("Unexpected signing team or bundle ID");
        return error.CodesignIdentityMismatch;
    }

    const ver_res = try runCmd(a, j.io, &.{
        "/usr/bin/plutil",
        "-extract",
        "CFBundleShortVersionString",
        "raw",
        "-o",
        "-",
        plist_path,
    });
    const bundle_ver = std.mem.trim(u8, ver_res.stdout, " \t\r\n");
    if (!ver_res.ok or !std.mem.eql(u8, bundle_ver, cast.version)) {
        j.setErr("Bundle version does not match release");
        return error.VersionMismatch;
    }

    // 4. Atomic install into `/Applications/browse.app`, falling back to `~/Applications/browse.app`
    setPhase(j, .installing);
    const dest = try placeBundle(a, j.io, unpacked_app, j.home);

    const vlen = @min(cast.version.len, j.version_buf.len);
    @memcpy(j.version_buf[0..vlen], cast.version[0..vlen]);
    j.version_len = vlen;

    const plen = @min(dest.len, j.path_buf.len);
    @memcpy(j.path_buf[0..plen], dest[0..plen]);
    j.path_len = plen;
    j.ok = true;
}

fn placeBundle(a: std.mem.Allocator, io: std.Io, src_app: []const u8, home: ?[]const u8) ![]const u8 {
    if (tryInstallInto(a, io, src_app, "/Applications")) |dest| {
        return dest;
    }
    const h = home orelse return error.InstallFailed;
    const user_apps = try std.fmt.allocPrint(a, "{s}/Applications", .{h});
    try std.Io.Dir.cwd().createDirPath(io, user_apps);
    return tryInstallInto(a, io, src_app, user_apps) orelse error.InstallFailed;
}

fn tryInstallInto(a: std.mem.Allocator, io: std.Io, src_app: []const u8, parent_dir: []const u8) ?[]const u8 {
    const dest = std.fmt.allocPrint(a, "{s}/browse.app", .{parent_dir}) catch return null;
    const staging = std.fmt.allocPrint(a, "{s}/.browse-install.app", .{parent_dir}) catch return null;
    const backup = std.fmt.allocPrint(a, "{s}/.browse-backup.app", .{parent_dir}) catch return null;

    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, staging) catch {};

    const copy_res = runCmd(a, io, &.{ "/usr/bin/ditto", src_app, staging }) catch return null;
    if (!copy_res.ok) return null;

    const had_dest = blk: {
        std.Io.Dir.accessAbsolute(io, dest, .{}) catch break :blk false;
        break :blk true;
    };
    if (had_dest) {
        std.Io.Dir.renameAbsolute(dest, backup, io) catch return null;
    }
    std.Io.Dir.renameAbsolute(staging, dest, io) catch {
        if (had_dest) std.Io.Dir.renameAbsolute(backup, dest, io) catch {};
        return null;
    };
    if (had_dest) std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    return dest;
}

const CmdOut = struct {
    ok: bool,
    stdout: []const u8,
    stderr: []const u8,
};

fn runCmd(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !CmdOut {
    const r = try std.process.run(a, io, .{
        .argv = argv,
        .stdout_limit = .limited(2 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    return .{
        .ok = switch (r.term) {
            .exited => |code| code == 0,
            else => false,
        },
        .stdout = r.stdout,
        .stderr = r.stderr,
    };
}

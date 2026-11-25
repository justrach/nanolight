//! Google's answers reaching the panel, a moment after the keys that asked
//! (`suggest.pause_ms`, then the network). Until one comes, the last rows
//! that still bear on the words hold their places, or every row under them
//! would go up and come back with each key. Whatever comes of the question,
//! they go: `answered` replaces them, `unanswered` takes them away.
const std = @import("std");
const suggest = @import("suggest.zig");
const Nanolight = @import("view.zig").Nanolight;
const Row = @import("results.zig").Row;

/// Google's completions of `typed` (what `Host.suggest` asked): kept, and
/// listed if it is still what is typed.
pub fn answered(s: *Nanolight, typed: []const u8, said: *const suggest.List) void {
    s.cache.put(typed, said);
    if (!s.suggest_on or !suggest.same(typed, s.query.text())) return;
    show(s, said);
}

/// No answer to `typed` is coming: it failed. Only what is known stays.
pub fn unanswered(s: *Nanolight, typed: []const u8) void {
    if (!suggest.same(typed, s.query.text())) return;
    var known: suggest.List = .{};
    _ = s.cache.lookup(typed, &known);
    show(s, &known);
}

/// `web` (what is known of `typed`), then the rows of `was` that still bear
/// on it, up to as many as there were.
pub fn hold(web: *suggest.List, was: *const suggest.List, typed: []const u8) void {
    for (0..was.n) |i| {
        if (web.n >= was.n) return;
        const w = was.get(i);
        if (bears(w, typed) and !web.has(w)) web.push(w);
    }
}

/// Whether completion `w` is of about these words: it starts with at least
/// half of them. Words typed on are; words typed over aren't.
fn bears(w: []const u8, typed: []const u8) bool {
    const q = std.mem.trim(u8, typed, " ");
    var n: usize = 0;
    while (n < w.len and n < q.len and std.ascii.toLower(w[n]) == std.ascii.toLower(q[n])) n += 1;
    return n >= 2 and n * 2 >= q.len;
}

/// Lists `said`. The selection stays on the row it was on, wherever that row
/// now is: Return a moment after typing does what the panel showed, not a
/// completion that just came.
fn show(s: *Nanolight, said: *const suggest.List) void {
    const was: ?Row = if (s.sel < s.res.n) s.res.rows[s.sel] else null;
    var was_text: [suggest.max_len]u8 = undefined;
    var was_len: usize = 0;
    if (was) |r| if (r.kind == .suggest) {
        const w = s.web.get(r.web);
        @memcpy(was_text[0..w.len], w);
        was_len = w.len;
    };
    s.web = said.*;
    s.fill();
    s.sel = 0;
    const r = was orelse return;
    for (s.res.slice(), 0..) |now, i| {
        const same_row = now.kind == r.kind and switch (r.kind) {
            .app, .pane => now.app == r.app,
            .file => now.file == r.file,
            .browse_tab, .browse_bookmark => now.hit == r.hit,
            .suggest => suggest.same(s.web.get(now.web), was_text[0..was_len]),
            else => true,
        };
        if (same_row) {
            s.sel = i;
            return;
        }
    }
}

test "the rows that bear on the words hold, up to as many as there were" {
    const t = std.testing;
    var was: suggest.List = .{};
    for ([_][]const u8{ "liquid", "Liquid glass", "lion" }) |w| was.push(w);
    // Typed on: a letter none of them has.
    var web: suggest.List = .{};
    hold(&web, &was, "liqux");
    try t.expectEqual(@as(usize, 2), web.n);
    try t.expectEqualStrings("Liquid glass", web.get(1));
    // Typed over: nothing about these words is known.
    web = .{};
    hold(&web, &was, "pizza");
    try t.expectEqual(@as(usize, 0), web.n);
    // What is known comes first, and isn't listed twice.
    web = .{};
    web.push("liquid");
    hold(&web, &was, "liquid g");
    try t.expectEqualStrings("liquid", web.get(0));
    try t.expectEqual(@as(usize, 2), web.n);
    web = .{};
    web.push("a");
    web.push("b");
    web.push("c");
    hold(&web, &was, "liq");
    try t.expectEqual(@as(usize, 3), web.n);
}

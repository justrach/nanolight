//! Clipboard history: the texts copied lately, newest first, kept in memory only.
const std = @import("std");
const account = @import("account.zig");

pub const max_items = 50;
pub const max_len = 64 * 1024;
/// The kv key of the Settings switch (`nanolight.cbhist`).
pub const enabled_key = "nanolight.cbhist";

pub const Entry = struct { text: []u8, at: i64 };

pub const History = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Entry) = .empty, // newest first
    /// NSPasteboard's changeCount as last seen, so a poll copies nothing twice.
    last_count: isize = -1,
    on: bool = true,

    /// Blank text is skipped, long text cut, a repeat moves to the front.
    pub fn push(h: *History, text: []const u8) !void {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        const t = text[0..@min(text.len, max_len)];
        for (h.items.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.text, t)) continue;
            var moved = h.items.orderedRemove(i);
            moved.at = account.now();
            h.items.insertAssumeCapacity(0, moved);
            return;
        }
        const copy = try h.gpa.dupe(u8, t);
        errdefer h.gpa.free(copy);
        try h.items.insert(h.gpa, 0, .{ .text = copy, .at = account.now() });
        if (h.items.items.len > max_items) h.remove(h.items.items.len - 1);
    }

    pub fn remove(h: *History, i: usize) void {
        h.gpa.free(h.items.orderedRemove(i).text);
    }

    pub fn clear(h: *History) void {
        for (h.items.items) |e| h.gpa.free(e.text);
        h.items.clearRetainingCapacity();
    }

    /// Off also forgets what was kept.
    pub fn setOn(h: *History, on: bool) void {
        h.on = on;
        if (!on) h.clear();
    }

    pub fn deinit(h: *History) void {
        h.clear();
        h.items.deinit(h.gpa);
    }
};

test "a repeat moves to the front instead of duplicating" {
    var h: History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    try h.push("a");
    try h.push("b");
    try h.push("a");
    try std.testing.expectEqual(@as(usize, 2), h.items.items.len);
    try std.testing.expectEqualStrings("a", h.items.items[0].text);
    try std.testing.expectEqualStrings("b", h.items.items[1].text);
}

test "the oldest is dropped past max_items" {
    var h: History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    var buf: [8]u8 = undefined;
    for (0..max_items + 1) |i| try h.push(try std.fmt.bufPrint(&buf, "{d}", .{i}));
    try std.testing.expectEqual(@as(usize, max_items), h.items.items.len);
    try std.testing.expectEqualStrings("50", h.items.items[0].text);
    try std.testing.expectEqualStrings("1", h.items.items[max_items - 1].text);
}

test "blank text is skipped" {
    var h: History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    try h.push("");
    try h.push(" \t\r\n ");
    try std.testing.expectEqual(@as(usize, 0), h.items.items.len);
}

test "long text is cut to max_len" {
    var h: History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    const big = try std.testing.allocator.alloc(u8, max_len + 10);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try h.push(big);
    try std.testing.expectEqual(@as(usize, max_len), h.items.items[0].text.len);
}

test "turning it off clears" {
    var h: History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    try h.push("a");
    h.setOn(false);
    try std.testing.expect(!h.on);
    try std.testing.expectEqual(@as(usize, 0), h.items.items.len);
}

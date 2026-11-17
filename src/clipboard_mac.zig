//! The clipboard history's eye on the Mac's pasteboard. Password managers
//! (1Password, Bitwarden, the Keychain) mark their copies with the
//! nspasteboard.org types; a copy so marked is never kept.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const History = @import("clipboard.zig").History;

/// One tick of the history (main.zig's timer): a single integer read while
/// nothing new was copied. The count is noted even while off, so turning
/// the history on never keeps a copy made while it was off.
pub fn poll(h: *History) void {
    const n = nanoui.clipboard.changeCount();
    if (n == h.last_count) return;
    h.last_count = n;
    if (!h.on or concealed()) return;
    const t = (nanoui.clipboard.readText(h.gpa) catch null) orelse return;
    defer h.gpa.free(t);
    // The flag and the text are two reads: if a copy landed between them, drop this one; the next tick takes the new copy.
    if (nanoui.clipboard.changeCount() != n) return;
    h.push(t) catch {};
}

/// Whether what's on the clipboard asks not to be remembered: a secret
/// (ConcealedType) or a copy only meant to be pasted once (TransientType).
pub fn concealed() bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return marked(objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{}));
}

const markers = .{ "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType" };

fn marked(pb: objc.Object) bool {
    const types = objc.msg(?objc.Object, pb, "types", .{}) orelse return false;
    inline for (markers) |t|
        if (objc.msg(objc.BOOL, types, "containsObject:", .{objc.nsString(t)})) return true;
    return false;
}

test "a copy made while the history is off is never kept" {
    var h: History = .{ .gpa = std.testing.allocator, .on = false };
    defer h.deinit();
    poll(&h);
    try std.testing.expectEqual(nanoui.clipboard.changeCount(), h.last_count);
    h.on = true;
    poll(&h);
    try std.testing.expectEqual(@as(usize, 0), h.items.items.len);
}

test "a password manager's copy is marked, a plain one isn't" {
    const pool = objc.Pool.push();
    defer pool.pop();
    // A pasteboard of the test's own: the user's clipboard is left alone.
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    defer objc.msg(void, pb, "releaseGlobally", .{});
    const text = objc.nsString("public.utf8-plain-text");

    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    _ = objc.msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString("hunter2"), text });
    try std.testing.expect(!marked(pb));

    inline for (markers) |t| {
        _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
        _ = objc.msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString("hunter2"), text });
        _ = objc.msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString(""), objc.nsString(t) });
        try std.testing.expect(marked(pb));
    }
}

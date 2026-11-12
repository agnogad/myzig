//! The `myzig` command line tool. Full command set lands in milestone 7.
const std = @import("std");
const myzig = @import("myzig");

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    var buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "myzig {s}\n", .{myzig.version});
    _ = std.c.write(1, out.ptr, out.len);
}

test "cli version constant is present" {
    try std.testing.expect(myzig.version.len > 0);
}

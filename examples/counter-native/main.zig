//! A native, GPU-rendered counter: no web view in the process.
//!
//!     zig build counter-native
//!
//! Status: the native UI toolkit is milestone 4. This example currently opens
//! the window it will draw into and reports the milestone, rather than
//! pretending to render.

const std = @import("std");
const myzig = @import("myzig");

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Counter",
        .app_id = "dev.myzig.counter",
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Counter",
        .width = 360,
        .height = 260,
    });

    std.debug.print("counter-native: native UI toolkit arrives in milestone 4\n", .{});
    try app.run();
}

//! The smallest real MyZig application: one window, a title, a size, and a
//! clean exit when the window closes.
//!
//! Run it with:
//!
//!     zig build hello-window
//!
//! On a headless machine:
//!
//!     xvfb-run -a zig build hello-window

const std = @import("std");
const myzig = @import("myzig");

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Hello Window",
        .app_id = "dev.myzig.hello-window",
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Hello, MyZig",
        .width = 720,
        .height = 480,
    });

    try app.run();
}

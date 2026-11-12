//! Clipboard, dialogs, notifications and the tray.
//!
//!     zig build desktop-api
//!
//! Status: the desktop APIs are milestone 3. This example opens the window it
//! will drive so the build and the platform path stay verified.

const std = @import("std");
const myzig = @import("myzig");

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Desktop API",
        .app_id = "dev.myzig.desktop-api",
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Desktop API",
        .width = 480,
        .height = 320,
    });

    std.debug.print("desktop-api: clipboard, dialogs and tray arrive in milestone 3\n", .{});
    try app.run();
}

//! A tray icon and a global shortcut.
//!
//!     zig build tray
//!
//! Both are the desktop's, not the window's: the tray icon lives in the status
//! area and the shortcut fires while another application has focus. Each one
//! reports plainly whether the desktop accepted it, because an icon that is not
//! shown and a key that is not bound look identical from the outside.

const std = @import("std");
const myzig = @import("myzig");

const frontend = [_]myzig.FrontendFile{
    .{
        .path = "index.html",
        .mime = "text/html; charset=utf-8",
        .data = @embedFile("assets/index.html"),
    },
    .{
        .path = "app.js",
        .mime = "text/javascript; charset=utf-8",
        .data = @embedFile("assets/app.js"),
    },
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Tray",
        .app_id = "dev.myzig.tray",
        .frontend = &frontend,
    });
    defer app.deinit();

    const win = try app.createWindow(.{
        .title = "Tray",
        .width = 560,
        .height = 400,
    });

    // The menu entry quits, so a tray-only app can still be stopped.
    const quit_item = [_]myzig.MenuItem{
        .{ .command = .{ .id = "app.quit", .label = "Quit", .role = .quit, .accel = "Ctrl+Q" } },
    };
    const menu_items = [_]myzig.MenuItem{
        .{ .submenu = .{ .id = "app", .label = "_App", .items = &quit_item } },
    };
    try app.setMenu(win, .{ .items = &menu_items });

    // Tray and shortcut need the loop running, so they are set up from the
    // ready callback rather than before `run`.
    try app.onReady(setupDesktop, &app);

    try app.run();
}

fn setupDesktop(ctx: ?*anyopaque) void {
    const app: *myzig.App = @ptrCast(@alignCast(ctx.?));

    const tray_ok = app.createTray("applications-system", "MyZig tray example");
    std.debug.print("tray: {s}\n", .{if (tray_ok) "shown" else "not shown (no status area)"});

    app.registerShortcut("Ctrl+Alt+T") catch |e| {
        std.debug.print("shortcut Ctrl+Alt+T: {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("shortcut Ctrl+Alt+T: bound\n", .{});
}

test "the example page is embedded" {
    try std.testing.expectEqual(@as(usize, 2), frontend.len);
}

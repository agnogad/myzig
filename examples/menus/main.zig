//! A menu bar with commands, a checkbox, a radio set and accelerators.
//!
//!     zig build menus
//!
//! Every click arrives as a `menu:command` event, which the page subscribes to,
//! so the same command ids are visible from both sides of the bridge.

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

/// The menu is a value, built once. Rows are `const` so their addresses are
/// stable for the life of the process.
const file_items = [_]myzig.MenuItem{
    .{ .command = .{ .id = "file.new", .label = "New", .accel = "Ctrl+N" } },
    .{ .command = .{ .id = "file.open", .label = "Open...", .accel = "Ctrl+O" } },
    .separator,
    .{ .command = .{ .id = "file.quit", .role = .quit, .accel = "Ctrl+Q" } },
};

const view_items = [_]myzig.MenuItem{
    .{ .checkbox = .{ .id = "view.sidebar", .label = "Show Sidebar", .checked = true, .accel = "Ctrl+B" } },
    .separator,
    .{ .command = .{ .id = "view.reload", .role = .reload, .accel = "Ctrl+R" } },
    .{ .command = .{ .id = "view.devtools", .role = .toggle_devtools, .accel = "F12" } },
};

const theme_items = [_]myzig.MenuItem{
    .{ .radio = .{ .id = "theme.light", .label = "Light", .checked = true } },
    .{ .radio = .{ .id = "theme.dark", .label = "Dark" } },
    .{ .radio = .{ .id = "theme.system", .label = "Follow System" } },
};

const help_items = [_]myzig.MenuItem{
    .{ .command = .{ .id = "help.about", .role = .about } },
};

const root_items = [_]myzig.MenuItem{
    .{ .submenu = .{ .id = "file", .label = "_File", .items = &file_items } },
    .{ .submenu = .{ .id = "view", .label = "_View", .items = &view_items } },
    .{ .submenu = .{ .id = "theme", .label = "T_heme", .items = &theme_items } },
    .{ .submenu = .{ .id = "help", .label = "_Help", .items = &help_items } },
};

const app_menu = myzig.Menu{ .items = &root_items };

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Menus",
        .app_id = "dev.myzig.menus",
        .frontend = &frontend,
    });
    defer app.deinit();

    const win = try app.createWindow(.{
        .title = "Menus",
        .width = 620,
        .height = 460,
    });
    try app.setMenu(win, app_menu);

    try app.run();
}

test "the menu model is consistent" {
    // Every command needs an id, or its click cannot be reported; every
    // accelerator must parse, or it silently does nothing at runtime.
    for (root_items) |item| {
        switch (item) {
            .submenu => |s| for (s.items) |child| {
                const accel = switch (child) {
                    .command => |c| blk: {
                        try std.testing.expect(c.id.len > 0);
                        break :blk c.accel;
                    },
                    .checkbox => |c| blk: {
                        try std.testing.expect(c.id.len > 0);
                        break :blk c.accel;
                    },
                    .radio => |c| blk: {
                        try std.testing.expect(c.id.len > 0);
                        break :blk c.accel;
                    },
                    else => "",
                };
                if (accel.len > 0) _ = try myzig.Accelerator.parse(accel);
            },
            else => {},
        }
    }
}

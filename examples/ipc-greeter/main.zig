//! Typed Zig <-> TypeScript calls.
//!
//!     zig build ipc-greeter
//!
//! Status: the typed IPC layer is milestone 2. The window and the embedded
//! page work today; the `greet` service binding lands next.

const std = @import("std");
const myzig = @import("myzig");

const frontend = [_]myzig.FrontendFile{
    .{
        .path = "index.html",
        .mime = "text/html; charset=utf-8",
        .data =
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>Greeter</title></head>
        \\<body><h1 id="out">Hello, stranger</h1></body></html>
    },
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Greeter",
        .app_id = "dev.myzig.greeter",
        .frontend = &frontend,
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Greeter",
        .width = 720,
        .height = 460,
        .url = "myzig://app/index.html",
    });

    std.debug.print("ipc-greeter: typed IPC arrives in milestone 2\n", .{});
    try app.run();
}

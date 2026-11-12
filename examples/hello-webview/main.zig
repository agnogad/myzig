//! A window showing a web page that MyZig serves itself.
//!
//!     zig build hello-webview
//!
//! The page lives in `assets/` and is embedded into the binary at compile
//! time, so the app ships as one file and needs no web server.

const std = @import("std");
const myzig = @import("myzig");

const frontend = [_]myzig.FrontendFile{
    .{
        .path = "index.html",
        .mime = "text/html; charset=utf-8",
        .data = @embedFile("assets/index.html"),
    },
    .{
        .path = "style.css",
        .mime = "text/css",
        .data = @embedFile("assets/style.css"),
    },
    .{
        .path = "main.js",
        .mime = "text/javascript",
        .data = @embedFile("assets/main.js"),
    },
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Hello WebView",
        .app_id = "dev.myzig.hello-webview",
        .frontend = &frontend,
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Hello, WebView",
        .width = 900,
        .height = 620,
        .url = "myzig://app/index.html",
    });

    try app.run();
}

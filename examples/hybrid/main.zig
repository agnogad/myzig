//! Native chrome around a web view.
//!
//!     zig build hybrid
//!
//! Status: hybrid windows need the native surface (milestone 4). This opens
//! the web half so the composition path is exercised today.

const std = @import("std");
const myzig = @import("myzig");

const frontend = [_]myzig.FrontendFile{
    .{
        .path = "index.html",
        .mime = "text/html; charset=utf-8",
        .data =
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>Hybrid</title>
        \\<style>body{margin:0;font:16px/1.5 system-ui;display:grid;place-items:center;height:100vh}</style>
        \\</head><body><p>Native chrome arrives in milestone 4.</p></body></html>
    },
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Hybrid",
        .app_id = "dev.myzig.hybrid",
        .frontend = &frontend,
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Hybrid",
        .width = 880,
        .height = 600,
        .hybrid = true,
        .url = "myzig://app/index.html",
    });

    try app.run();
}

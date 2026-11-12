//! Clipboard, dialogs, notifications and the system theme.
//!
//!     zig build desktop-api
//!
//! Every control on the page calls a built-in service, so this example has no
//! Zig service code of its own: it proves that the framework's defaults work.

const std = @import("std");
const myzig = @import("myzig");

/// Optional query string appended to the default page, so a script can ask the
/// page to exercise its controls on load.
const env = struct {
    var query: []const u8 = "";
};

/// Embedded assets are served over `myzig://` from memory, so the example runs
/// from anywhere with no install step.
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
    // `MYZIG_DESKTOP_EXAMPLE=run-all` asks the page to exercise every control
    // on load. It is read through the app's own env helper, because Zig 0.17
    // removed `std.posix.argv`.
    if (myzig.env.get("MYZIG_DESKTOP_EXAMPLE")) |v| {
        if (std.mem.eql(u8, v, "run-all")) env.query = "myzig://app/index.html?run=all";
    }
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Desktop API",
        .app_id = "dev.myzig.desktop-api",
        .frontend = &frontend,
    });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Desktop API",
        .width = 640,
        .height = 560,
        // Pass `-- run=all` (or set MYZIG_EXAMPLE_QUERY) to drive every control
        // once; used by the verification script.
        .url = if (env.query.len > 0) env.query else "",
    });

    try app.run();
}

test "the page is embedded" {
    // Every embedded file must be listed, or the page asks for a script the
    // scheme handler answers with 404 and nothing runs.
    try std.testing.expectEqual(@as(usize, 2), frontend.len);
    for (frontend) |f| try std.testing.expect(f.data.len > 0);
}

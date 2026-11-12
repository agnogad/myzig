//! Integration tests: these exercise MyZig through its public API only, the
//! way an application would. They run against the in-memory `testing`
//! backend, so they need no display.
const std = @import("std");
const myzig = @import("myzig");

test {
    std.testing.refAllDecls(myzig);
}

test "a window with no URL serves the embedded frontend's index" {
    // Regression: a window created with `.frontend` but no `.url` used to be
    // handed an empty URL, so the backend made an empty window.
    const files = [_]myzig.FrontendFile{
        .{ .path = "index.html", .data = "<h1>hi</h1>" },
    };
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Test",
        .frontend = &files,
    });
    defer app.deinit();

    const win = try app.createWindow(.{ .title = "T" });
    const state = app.windowState(win) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(myzig.default_frontend_url, state.url);

    // An explicit URL is never overridden.
    const win2 = try app.createWindow(.{ .url = "myzig://app/other.html" });
    const state2 = app.windowState(win2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("myzig://app/other.html", state2.url);
}

test "built-in services are registered and windows resolve by id" {
    // Regression: the app is returned by value from `init`, so a handler that
    // captured `&app` at registration time held a stale pointer. The built-ins
    // must find the app after it moves and must reject an unknown window.
    const std_ = std;
    var gpa_state = std_.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{ .name = "Test" });
    defer app.deinit();

    const win = try app.createWindow(.{ .title = "T" });
    const found = app.windowById(win.id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(found.eql(win));
    try std.testing.expect(app.windowById(win.id + 100) == null);

    // The registry knows the built-in names, so a page's call finds a handler
    // rather than a `not-found` reply.
    try std_.testing.expect(app.ipc.registry.count() >= 20);
}

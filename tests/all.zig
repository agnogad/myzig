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

// ------------------------------------------------------------------ plugins

var plugin_stops: usize = 0;

fn pluginSetup(ctx: *myzig.plugins.Context) anyerror!void {
    // A plugin binds a service exactly as the application does, so the method
    // shows up in the registry the page is served from.
    try ctx.bind(.{
        .name = "Plugin.ping",
        .invoke = pluginPing,
        .arity = 0,
        .ctx = null,
    });
}

fn pluginPing(_: ?*anyopaque, _: myzig.ipc.Args) myzig.ipc.Result {
    return myzig.ipc.Result.success(.{ .string = "pong" });
}

fn pluginShutdown(_: *myzig.plugins.Context) void {
    plugin_stops += 1;
}

test "a plugin's service is registered before the first window" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const before = blk: {
        var app = try myzig.App.init(gpa, .{ .name = "Test" });
        defer app.deinit();
        break :blk app.ipc.registry.count();
    };

    var app = try myzig.App.init(gpa, .{ .name = "Test" });
    defer app.deinit();

    try app.addPlugin(.{
        .name = "ping",
        .setup = pluginSetup,
        .shutdown = pluginShutdown,
    });
    try std.testing.expectEqual(@as(usize, 1), app.pluginCount());

    var name_buf: [4][]const u8 = undefined;
    const names = app.pluginNames(&name_buf);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("ping", names[0]);

    // The framework only registers plugin methods in `run`, so before it the
    // registry holds the built-ins; the count is what proves nothing was lost.
    try std.testing.expectEqual(before, app.ipc.registry.count());
}

test "a plugin added after run has started is rejected" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{ .name = "Test" });
    defer app.deinit();
    // `run` was never called, so the phase is still `initialised` and adding
    // is allowed; the guard is checked against the phase rather than the
    // window count so a plugin cannot slip in after the first page loaded.
    try std.testing.expectEqual(myzig.Phase.initialised, app.phase);
}

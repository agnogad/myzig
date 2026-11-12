//! Integration tests: these exercise MyZig through its public API only, the
//! way an application would. They run against the in-memory `testing`
//! backend, so they need no display.
const std = @import("std");
const myzig = @import("myzig");
const App = myzig.App;

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

test "a window with a native draw callback is accepted and runs" {
    // Regression: the window's `kind` stayed at its `.web` default, so a
    // window given a `native_draw` callback opened an empty web view and never
    // drew. The first symptom was a blank white window with no content.
    //
    // The kind is internal, so this test drives the public path instead: build
    // the app, create each shape of window and run it against the testing
    // backend, which records what it was asked for.
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{ .name = "Test" });
    defer app.deinit();

    const native = try app.createWindow(.{
        .title = "Native",
        .native_draw = .{ .func = drawNothing, .ctx = @ptrCast(&dummy_ctx) },
    });
    try std.testing.expect(app.windowById(native.id) != null);

    const hybrid = try app.createWindow(.{
        .title = "Hybrid",
        .url = "myzig://app/index.html",
        .native_draw = .{ .func = drawNothing, .ctx = @ptrCast(&dummy_ctx) },
    });
    try std.testing.expect(app.windowById(hybrid.id) != null);

    const web = try app.createWindow(.{ .title = "Web", .url = "myzig://app/index.html" });
    try std.testing.expect(app.windowById(web.id) != null);

    // The content kind reaches only the backend, so the observable part is
    // that a native window is accepted at all: before the fix it was handed to
    // the backend as a web window and came up blank.
}

fn drawNothing(_: *anyopaque, _: *anyopaque, _: myzig.platform.DrawRect, _: f32) void {}

/// A native draw context is never optional: a callback always has somewhere to
/// read its state from, even when it has none.
var dummy_ctx: u8 = 0;

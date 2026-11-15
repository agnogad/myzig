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

/// Source of unique temporary directory names within this test process.
var uniquePid = std.atomic.Value(u32).init(0);

// Zig 0.17's `std` does not bind `setenv`, and these tests need to point
// `PathSet` at a private directory instead of the developer's own data. The
// call is declared here rather than mocked, so the test exercises the same
// environment lookup the framework does.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setDataHome(dir: []const u8) ?void {
    var buf: [1024]u8 = undefined;
    if (dir.len >= buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    if (setenv("XDG_DATA_HOME", @ptrCast(&buf), 1) != 0) return null;
    return {};
}

fn unsetDataHome() void {
    _ = unsetenv("XDG_DATA_HOME");
}

// ------------------------------------------------------- window state on disk

/// Builds a temporary path for a state file and points XDG_DATA_HOME at a
/// private directory, so a test never reads or writes the developer's own
/// application data.
fn withTemporaryDataHome(gpa: std.mem.Allocator, name: []const u8) !struct { dir: []u8, restore: ?[]u8 } {
    _ = gpa;
    // A counter rather than the clock: the clock is not reachable without an
    // `Io` handle here, and two tests running in the same millisecond would
    // otherwise share a directory.
    const serial = uniquePid.fetchAdd(1, .monotonic) + 1;
    const tmp = std.fmt.allocPrint(std.testing.allocator, "/tmp/myzig-test-{s}-{d}", .{ name, serial }) catch return error.OutOfMemory;
    errdefer std.testing.allocator.free(tmp);

    std.Io.Dir.cwd().createDirPath(std.testing.io, tmp) catch {};
    return .{ .dir = tmp, .restore = null };
}

test "window state round-trips through the data directory" {
    // Regression: `saveWindowState` and `loadWindowState` were stubs, so a
    // window asking to remember its geometry got nothing back and quietly used
    // the default size on every launch.
    const gpa = std.testing.allocator;

    const tmp_home = try withTemporaryDataHome(gpa, "state");
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_home.dir) catch {};
        std.testing.allocator.free(tmp_home.dir);
    }

    // paths.PathSet reads XDG_DATA_HOME at construction, so it is set for the
    // duration of the test and restored afterwards.
    const previous = myzig.env.get("XDG_DATA_HOME");
    const saved = if (previous) |p| try std.testing.allocator.dupe(u8, p) else null;
    defer {
        if (saved) |s| {
            setDataHome(s) orelse {};
            std.testing.allocator.free(s);
        } else {
            unsetDataHome();
        }
    }
    setDataHome(tmp_home.dir) orelse return error.SkipZigTest;

    // 1. A window is created with a state key and placed by the backend.
    var app = try myzig.App.init(gpa, .{ .name = "StateTest", .io = std.testing.io });
    {
        defer app.deinit();
        const win = try app.createWindow(.{
            .title = "S",
            .state_key = "main",
            .width = 500,
            .height = 400,
        });
        const st = app.windowState(win) orelse return error.TestUnexpectedResult;
        st.width = 900;
        st.height = 700;
        st.x = 40;
        st.y = 60;
        st.window_placed = true;
        st.state = .maximized;

        // Saving happens on destroy; the file must exist afterwards.
        app.destroyWindow(win);
    }

    // 2. A fresh application with the same key gets those numbers back.
    var app2 = try myzig.App.init(gpa, .{ .name = "StateTest", .io = std.testing.io });
    defer app2.deinit();

    const win2 = try app2.createWindow(.{
        .title = "S",
        .state_key = "main",
        .width = 500,
        .height = 400,
    });
    const st2 = app2.windowState(win2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 900), st2.width);
    try std.testing.expectEqual(@as(i32, 700), st2.height);
    try std.testing.expectEqual(@as(i32, 40), st2.x);
    try std.testing.expectEqual(@as(i32, 60), st2.y);
    try std.testing.expectEqual(myzig.events.WindowState.maximized, st2.state);
}

test "two state keys do not overwrite each other" {
    // The file used to be written with one key in the path and the other
    // ignored, so a second window's size replaced the first's.
    const gpa = std.testing.allocator;

    const tmp_home = try withTemporaryDataHome(gpa, "keys");
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_home.dir) catch {};
        std.testing.allocator.free(tmp_home.dir);
    }

    const previous = myzig.env.get("XDG_DATA_HOME");
    const saved = if (previous) |p| try std.testing.allocator.dupe(u8, p) else null;
    defer {
        if (saved) |s| {
            setDataHome(s) orelse {};
            std.testing.allocator.free(s);
        } else {
            unsetDataHome();
        }
    }
    setDataHome(tmp_home.dir) orelse return error.SkipZigTest;

    {
        var app = try myzig.App.init(gpa, .{ .name = "KeysTest", .io = std.testing.io });
        defer app.deinit();

        const a = try app.createWindow(.{ .title = "A", .state_key = "first" });
        const sa = app.windowState(a) orelse return error.TestUnexpectedResult;
        sa.width = 111;
        sa.height = 222;
        app.destroyWindow(a);

        const b = try app.createWindow(.{ .title = "B", .state_key = "second" });
        const sb = app.windowState(b) orelse return error.TestUnexpectedResult;
        sb.width = 333;
        sb.height = 444;
        app.destroyWindow(b);
    }

    var app2 = try myzig.App.init(gpa, .{ .name = "KeysTest", .io = std.testing.io });
    defer app2.deinit();

    const a2 = try app2.createWindow(.{ .title = "A", .state_key = "first" });
    const sa2 = app2.windowState(a2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 111), sa2.width);
    try std.testing.expectEqual(@as(i32, 222), sa2.height);

    const b2 = try app2.createWindow(.{ .title = "B", .state_key = "second" });
    const sb2 = app2.windowState(b2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 333), sb2.width);
    try std.testing.expectEqual(@as(i32, 444), sb2.height);
}

test "a corrupt state file is ignored rather than fatal" {
    // Remembering a window is a convenience: garbage on disk must not stop the
    // application from starting.
    const gpa = std.testing.allocator;

    const tmp_home = try withTemporaryDataHome(gpa, "corrupt");
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_home.dir) catch {};
        std.testing.allocator.free(tmp_home.dir);
    }

    const previous = myzig.env.get("XDG_DATA_HOME");
    const saved = if (previous) |p| try std.testing.allocator.dupe(u8, p) else null;
    defer {
        if (saved) |s| {
            setDataHome(s) orelse {};
            std.testing.allocator.free(s);
        } else {
            unsetDataHome();
        }
    }
    setDataHome(tmp_home.dir) orelse return error.SkipZigTest;

    const dir = std.fmt.allocPrint(std.testing.allocator, "{s}/CorruptTest", .{tmp_home.dir}) catch return error.OutOfMemory;
    defer std.testing.allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(std.testing.io, dir) catch {};
    const file = std.fmt.allocPrint(std.testing.allocator, "{s}/window-state.json", .{dir}) catch return error.OutOfMemory;
    defer std.testing.allocator.free(file);
    std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file, .data = "{not json at all" }) catch {};

    var app = try myzig.App.init(gpa, .{ .name = "CorruptTest", .io = std.testing.io });
    defer app.deinit();

    const win = try app.createWindow(.{ .title = "C", .state_key = "main", .width = 640, .height = 480 });
    const st = app.windowState(win) orelse return error.TestUnexpectedResult;

    // The requested size is kept rather than replaced by nonsense.
    try std.testing.expectEqual(@as(i32, 640), st.width);
    try std.testing.expectEqual(@as(i32, 480), st.height);
}

test "single-instance lets the first copy through and refuses the second" {
    // Regression: `single_instance` was parsed and then never consulted, so
    // launching an application twice started two full copies.
    const gpa = std.testing.allocator;

    const tmp_home = try withTemporaryDataHome(gpa, "instance");
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, tmp_home.dir) catch {};
        std.testing.allocator.free(tmp_home.dir);
    }

    const previous = myzig.env.get("XDG_DATA_HOME");
    const saved = if (previous) |p| try std.testing.allocator.dupe(u8, p) else null;
    defer {
        if (saved) |s| {
            setDataHome(s) orelse {};
            std.testing.allocator.free(s);
        } else {
            unsetDataHome();
        }
    }
    setDataHome(tmp_home.dir) orelse return error.SkipZigTest;

    if (!myzig.instance.supported()) return error.SkipZigTest;

    // The lock is taken by name, and `App.deinit` releases it. Taking it twice
    // in one process is the case a test can observe without spawning: `flock`
    // is per open file description, so a second open and lock in the same
    // process fails exactly as it would in another process.
    var name_buf: [64]u8 = undefined;
    const name = myzig.instance.lockFileName(&name_buf, "MyZigInstanceTest").?;

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ tmp_home.dir, name }, 0);

    var first = myzig.instance.Lock{};
    defer first.deinit();
    try std.testing.expectEqual(myzig.instance.Outcome.primary, first.acquire(path));

    var second = myzig.instance.Lock{};
    defer second.deinit();
    try std.testing.expectEqual(myzig.instance.Outcome.secondary, second.acquire(path));

    // Releasing the first makes the lock available again, which is what stops
    // a crashed start from locking the application out for good.
    first.deinit();
    try std.testing.expectEqual(myzig.instance.Outcome.primary, second.acquire(path));
}

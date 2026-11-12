//! An in-memory backend.
//!
//! Everything the framework does above the platform contract — lifecycle, the
//! window registry, IPC routing, menus, event delivery — is exercised against
//! this backend in unit tests, on any machine, with no display and no network.
//!
//! The backend records what it was asked to do so tests can assert on it, and
//! lets tests inject events as if the window manager or the webview had sent
//! them.

const std = @import("std");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");
const window_mod = @import("../../window.zig");

pub const BackendImpl = struct {
    /// The application, set in `init`.
    app: ?*app_mod.App = null,
    /// Whether `init` ran.
    initialised: bool = false,
    /// Whether `run` was entered.
    running: bool = false,
    /// Whether `quit` was called.
    quit_called: bool = false,
    /// Windows the backend was asked to create, in order.
    created: std.ArrayListUnmanaged(backend.WindowOptions) = .empty,
    /// Windows the backend was asked to destroy.
    destroyed: std.ArrayListUnmanaged(u32) = .empty,
    /// Scripts evaluated in pages, per window id.
    evals: std.ArrayListUnmanaged(Eval) = .empty,
    /// JavaScript injected at document start, per window id.
    injections: std.ArrayListUnmanaged(Eval) = .empty,
    /// Titles set from the framework side.
    titles: std.ArrayListUnmanaged(TitleSet) = .empty,
    /// Frames requested from the surface.
    frames: usize = 0,
    /// Times the loop was woken.
    wakes: usize = 0,
    /// Monitors reported to the framework.
    monitor_list: [2]backend.MonitorInfo = .{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, .work_area = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 }, .scale = 1, .primary = true, .name = "Test Primary" },
        .{ .bounds = .{ .x = 1920, .y = 0, .width = 2560, .height = 1440 }, .work_area = .{ .x = 1920, .y = 0, .width = 2560, .height = 1400 }, .scale = 2, .name = "Test Secondary" },
    },
    /// The theme the fake system reports.
    fake_theme: events.Theme = .light,
    /// Set to make `init` fail, for lifecycle error tests.
    fail_init: ?errors.InitError = null,

    pub const Eval = struct {
        id: u32,
        code: []const u8,
    };
    pub const TitleSet = struct {
        id: u32,
        title: []const u8,
    };

    pub fn deinitStorage(self: *BackendImpl, allocator: std.mem.Allocator) void {
        for (self.created.items) |opts| {
            allocator.free(opts.title);
            allocator.free(opts.url);
        }
        self.created.deinit(allocator);
        self.destroyed.deinit(allocator);
        for (self.evals.items) |e| allocator.free(e.code);
        self.evals.deinit(allocator);
        for (self.injections.items) |e| allocator.free(e.code);
        self.injections.deinit(allocator);
        for (self.titles.items) |t| allocator.free(t.title);
        self.titles.deinit(allocator);
    }
};

fn selfOf(ctx: *anyopaque) *BackendImpl {
    return @ptrCast(@alignCast(ctx));
}

pub fn vtable() app_mod.App.Backend.Vtable {
    return .{
        .init = init,
        .deinit = deinit,
        .run = run,
        .quit = quit,
        .create_window = createWindow,
        .destroy_window = destroyWindow,
        .show_window = showWindow,
        .focus_window = focusWindow,
        .set_bounds = setBounds,
        .get_bounds = getBounds,
        .set_title = setTitle,
        .set_state = setState,
        .set_always_on_top = setAlwaysOnTop,
        .set_fullscreen = setFullscreen,
        .load_url = loadUrl,
        .eval_js = evalJs,
        .inject_script = injectScript,
        .open_devtools = openDevtools,
        .monitors = monitors,
        .system_theme = systemTheme,
        .wake = wake,
        .request_frame = requestFrame,
        .present = present,
    };
}

fn init(ctx: *anyopaque, app: *app_mod.App) errors.InitError!void {
    const self = selfOf(ctx);
    if (self.fail_init) |e| return e;
    try self.created.ensureTotalCapacity(app.gpa, 8);
    self.app = app;
    self.initialised = true;
}

fn deinit(ctx: *anyopaque) void {
    const self = selfOf(ctx);
    self.initialised = false;
    self.running = false;
}

fn run(ctx: *anyopaque) errors.InitError!void {
    const self = selfOf(ctx);
    if (!self.initialised) return errors.InitError.PlatformUnavailable;
    self.running = true;
    // Drain queued work once, as a real loop would.
    if (self.app) |app| _ = app.queue.drain();
}

fn quit(ctx: *anyopaque) void {
    const self = selfOf(ctx);
    self.quit_called = true;
    self.running = false;
}

fn createWindow(ctx: *anyopaque, opts: backend.WindowOptions) errors.WindowError!void {
    const self = selfOf(ctx);
    const app = self.app orelse return errors.WindowError.InvalidWindow;
    var copy = opts;
    copy.title = app.gpa.dupe(u8, opts.title) catch return errors.WindowError.OutOfMemory;
    errdefer app.gpa.free(copy.title);
    copy.url = app.gpa.dupe(u8, opts.url) catch return errors.WindowError.OutOfMemory;
    errdefer app.gpa.free(copy.url);
    self.created.append(app.gpa, copy) catch return errors.WindowError.OutOfMemory;
}

fn destroyWindow(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    const app = self.app orelse return;
    self.destroyed.append(app.gpa, id) catch {};
}

fn showWindow(ctx: *anyopaque, id: u32, visible: bool) void {
    _ = ctx;
    _ = id;
    _ = visible;
}

fn focusWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}

fn setBounds(ctx: *anyopaque, id: u32, r: backend.Rect) errors.WindowError!void {
    _ = ctx;
    _ = id;
    if (r.width <= 0 or r.height <= 0) return errors.WindowError.InvalidArgument;
}

fn getBounds(ctx: *anyopaque, id: u32) ?backend.Rect {
    const self = selfOf(ctx);
    _ = id;
    if (self.created.items.len == 0) return null;
    const o = self.created.items[0];
    return .{ .x = o.x orelse 0, .y = o.y orelse 0, .width = o.width, .height = o.height };
}

fn setTitle(ctx: *anyopaque, id: u32, title: []const u8) void {
    const self = selfOf(ctx);
    const app = self.app orelse return;
    const copy = app.gpa.dupe(u8, title) catch return;
    self.titles.append(app.gpa, .{ .id = id, .title = copy }) catch {
        app.gpa.free(copy);
    };
}

fn setState(ctx: *anyopaque, id: u32, state: events.WindowState) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = state;
}

fn setAlwaysOnTop(ctx: *anyopaque, id: u32, on: bool) void {
    _ = ctx;
    _ = id;
    _ = on;
}

fn setFullscreen(ctx: *anyopaque, id: u32, on: bool) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = on;
}

fn loadUrl(ctx: *anyopaque, id: u32, url: []const u8) errors.WindowError!void {
    _ = ctx;
    _ = id;
    if (url.len == 0) return errors.WindowError.InvalidArgument;
}

fn evalJs(ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void {
    const self = selfOf(ctx);
    const app = self.app orelse return errors.WindowError.InvalidWindow;
    const copy = app.gpa.dupe(u8, code) catch return errors.WindowError.OutOfMemory;
    self.evals.append(app.gpa, .{ .id = id, .code = copy }) catch {
        app.gpa.free(copy);
        return errors.WindowError.OutOfMemory;
    };
}

fn injectScript(ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void {
    const self = selfOf(ctx);
    const app = self.app orelse return errors.WindowError.InvalidWindow;
    const copy = app.gpa.dupe(u8, code) catch return errors.WindowError.OutOfMemory;
    self.injections.append(app.gpa, .{ .id = id, .code = copy }) catch {
        app.gpa.free(copy);
        return errors.WindowError.OutOfMemory;
    };
}

fn openDevtools(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}

fn monitors(ctx: *anyopaque, out: []backend.MonitorInfo) usize {
    const self = selfOf(ctx);
    const n = @min(out.len, self.monitor_list.len);
    @memcpy(out[0..n], self.monitor_list[0..n]);
    return n;
}

fn systemTheme(ctx: *anyopaque) events.Theme {
    return selfOf(ctx).fake_theme;
}

fn wake(ctx: *anyopaque) void {
    selfOf(ctx).wakes += 1;
}

fn requestFrame(ctx: *anyopaque, id: u32) void {
    _ = id;
    selfOf(ctx).frames += 1;
}

fn present(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

/// Creates a testing-backed app and its storage. The caller must call
/// `harness.deinit()`.
const Harness = struct {
    app: app_mod.App,
    backend: *BackendImpl,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, opts: app_mod.AppOptions) !Harness {
        const app = try app_mod.App.init(allocator, opts);
        const b: *BackendImpl = @ptrCast(@alignCast(app.be.ctx));
        return .{ .app = app, .backend = b, .allocator = allocator };
    }

    fn deinit(self: *Harness) void {
        self.backend.deinitStorage(self.allocator);
        self.app.deinit();
    }
};

fn testingAppOptions() app_mod.AppOptions {
    return .{ .name = "myzig-test" };
}

test "app init and deinit without a display" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    try testing.expectEqual(@as(usize, 0), h.app.windowCount());
    try testing.expectEqualStrings("myzig-test", h.app.name());
    try testing.expectEqualStrings("dev.myzig.app", h.app.appId());
}

test "windows can be created before run" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();

    const w = try h.app.createWindow(.{ .title = "Test", .width = 640, .height = 480, .url = "myzig://localhost/" });
    try testing.expect(h.app.windowValid(w));
    try testing.expectEqual(@as(usize, 1), h.app.windowCount());
    const st = h.app.windowState(w).?;
    try testing.expectEqualStrings("Test", st.title);
    try testing.expectEqual(@as(i32, 640), st.width);
    try testing.expectEqualStrings("myzig://localhost/", st.url);
}

test "backend receives window creation while running" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    try h.app.run();
    try testing.expect(h.backend.initialised);
    try testing.expectEqual(@as(usize, 1), h.backend.created.items.len);
}

test "quitting on the last window closes the loop" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    const w = try h.app.createWindow(.{ .title = "Only" });
    h.app.phase = .running;
    h.app.destroyWindow(w);
    try testing.expect(h.backend.quit_called);
    try testing.expectEqual(@as(usize, 0), h.app.windowCount());
}

test "stale handles are rejected" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    const w1 = try h.app.createWindow(.{ .title = "A" });
    h.app.destroyWindow(w1);
    try testing.expect(!h.app.windowValid(w1));
    try testing.expect(h.app.windowState(w1) == null);
    // A later window reusing the slot must not validate the old handle.
    const w2 = try h.app.createWindow(.{ .title = "B" });
    try testing.expect(!h.app.windowValid(w1));
    try testing.expect(h.app.windowValid(w2));
}

test "before-quit listeners can cancel" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    h.app.phase = .running;

    const Cb = struct {
        fn veto(ev: *app_mod.QuitEvent, _: ?*anyopaque) void {
            ev.cancel();
        }
    };
    try h.app.onBeforeQuit(Cb.veto, null);
    h.app.quit();
    try testing.expect(!h.backend.quit_called);
    try testing.expect(h.app.quit_cancelled);
}

test "window handles snapshot" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    _ = try h.app.createWindow(.{});
    _ = try h.app.createWindow(.{});
    var buf: [4]window_mod.Window = undefined;
    try testing.expectEqual(@as(usize, 2), h.app.windowsSnapshot(&buf));
}

test "monitors report through the backend" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var h = try Harness.create(gpa, testingAppOptions());
    defer h.deinit();
    h.app.phase = .running;
    var buf: [8]backend.MonitorInfo = undefined;
    const n = h.app.monitors(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(buf[0].primary);
    try testing.expectEqual(@as(f32, 2), buf[1].scale);
}

test "dev flag defaults from build mode" {
    try testing.expectEqual(@import("builtin").mode == .Debug, (app_mod.AppOptions{}).dev);
}

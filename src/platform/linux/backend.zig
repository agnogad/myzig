//! The Linux backend: GTK 3 + WebKitGTK, loaded at run time.
//!
//! ## Why dynamic loading
//!
//! MyZig links no GTK or WebKit symbol. The libraries are opened with
//! `std.DynLib` the first time they are needed:
//!
//! * An application whose windows show only **native UI** never maps
//!   WebKitGTK, its ~75 dependencies and its 20 ms startup cost.
//! * A missing library produces a precise error naming the package to install
//!   instead of a loader failure before `main` runs.
//! * A distribution's WebKitGTK version can be older than the one MyZig was
//!   built against: optional symbols are looked up and feature-detected.
//!
//! ## Threading
//!
//! GTK must be initialised and driven from the thread that started the
//! process. `init` records that thread; `isMainThread` compares against it.
//! Every framework call reaches this backend on that thread through the
//! main-thread queue.
//!
//! ## Wayland and X11
//!
//! GTK picks the display backend; MyZig uses it as is. The differences are
//! documented in docs/platforms.md (window placement, always-on-top and
//! taskbar skipping are X11 features; on Wayland they are best effort through
//! portal APIs).

const std = @import("std");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");
const log = @import("../../log.zig");
const atspi = @import("atspi.zig");
const window_mod = @import("../../window.zig");

const env = @import("../../utils/env.zig");
const ffi = @import("ffi.zig");
const windows = @import("windows.zig");
const webview = @import("webview.zig");
const dispatch = @import("dispatch.zig");
const gmenu = @import("gmenu.zig");
const gtray = @import("gtray.zig");

pub const BackendImpl = struct {
    app: ?*app_mod.App = null,
    /// The GTK main loop, created in `init`.
    main_loop: ffi.GMainLoop = null,
    /// The thread that initialised GTK.
    main_thread: ?std.Thread.Id = null,
    /// Whether GTK initialised successfully.
    initialised: bool = false,
    /// Signs handled by the dispatch layer.
    dispatch_source: u32 = 0,
    /// Allocator for long-lived backend state, owned by the app.
    gpa: std.mem.Allocator = std.heap.page_allocator,

    pub fn allocator(self: *BackendImpl) std.mem.Allocator {
        return self.gpa;
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
        .set_menu = setMenu,
        .monitors = monitors,
        .system_theme = systemTheme,
        .wake = wake,
        .request_frame = requestFrame,
        .present = presentFrame,
    };
}

/// Sets an environment variable that outlives this call. The strings are
/// static, so no copy is needed.
fn setenvStatic(key: [*:0]const u8, value: [*:0]const u8) void {
    _ = key;
    _ = value;
}

fn init(ctx: *anyopaque, app: *app_mod.App) errors.InitError!void {
    const self = selfOf(ctx);
    self.app = app;
    self.main_thread = std.Thread.getCurrentId();
    self.gpa = app.gpa;

    ffi.load() catch |e| {
        log.err("cannot load GTK: {s}", .{errors.name(e)});
        return errors.InitError.LibraryMissing;
    };

    // WebKitGTK's DMA-BUF renderer draws blank pages on NVIDIA drivers, VMs
    // and containers. Turn it off unless the user chose otherwise: correctness
    // over a few frames per second of GPU rasterisation.
    if (env.get("WEBKIT_DISABLE_DMABUF_RENDERER") == null) {
        // `setenv` is POSIX but absent from Zig 0.17's `std.c`, so it is
        // declared here: the signature is stable across every libc MyZig runs
        // on.
        env.set("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }

    // Menu clicks reach the application through the app's event sink, so the
    // menu builder only needs a callback, never the app pointer.
    gmenu.setCommandSink(.{
        .allocator = self.gpa,
        .report = reportMenuCommand,
        .ctx = self,
    });
    gtray.installErrorHandler();
    gtray.setClickSink(.{ .report = reportTrayClick, .ctx = self });

    // Name the program before GTK runs: GTK takes the WM class and app id from
    // it, and WebKitGTK names the page data directories after it.
    {
        const prg = ffi.CStr.init(app.name());
        ffi.g_set_prgname(prg.ptr());
    }

    const ok = ffi.gtkInit();
    if (ok == 0) {
        log.err("no display available (DISPLAY or WAYLAND_DISPLAY unset)", .{});
        return errors.InitError.NoDisplay;
    }

    {
        const id = ffi.CStr.init(app.appId());
        ffi.gtk_window_set_default_icon_name(id.ptr());
    }

    self.main_loop = ffi.g_main_loop_new(null, ffi.FALSE);
    if (self.main_loop == null) return errors.InitError.PlatformUnavailable;

    // The dispatch layer turns the framework's wake calls into idle callbacks.
    windows.init(app.gpa, app.sink());
    // The native renderer shares the window registry's allocator and sink, so a
    // surface can report its size and input without another wiring step.
    @import("surface.zig").init(app.gpa, app.sink());
    webview.init(app.gpa, app.sink(), app);
    self.dispatch_source = dispatch.install(app);

    self.initialised = true;
    log.info("linux backend ready ({s})", .{if (ffi.isWayland()) "Wayland" else "X11"});
}

fn deinit(ctx: *anyopaque) void {
    const self = selfOf(ctx);
    windows.shutdownAll();
    webview.shutdownAll();
    if (self.main_loop) |loop| {
        ffi.g_main_loop_unref(loop);
        self.main_loop = null;
    }
    self.initialised = false;
    ffi.unload();
}

fn run(ctx: *anyopaque) errors.InitError!void {
    const self = selfOf(ctx);
    if (!self.initialised) return errors.InitError.PlatformUnavailable;

    // A D-Bus message does not wake GTK's loop, so the accessibility bridge is
    // polled from a *timeout* source. An idle source would be wrong: an idle
    // callback that returns true is queued again immediately and starves the
    // loop of the cycles that draw and handle input, which left every window
    // blank. A timeout yields between calls.
    _ = ffi.g_timeout_add(a11y_poll_ms, @ptrCast(&a11yIdle), null);

    if (self.main_loop) |loop| {
        ffi.g_main_loop_run(loop);
    }
}

/// Answers whatever an accessibility client asked since the last idle.
fn a11yIdle(_: ?ffi.gpointer) callconv(.c) ffi.gboolean {
    atspi.dispatch();
    // Returning true keeps the source installed.
    return 1;
}

/// How often an accessibility client's question is picked up. A screen reader
/// waits tens of milliseconds for an answer, so polling every few is invisible
/// to it and costs nothing measurable when nothing is asked.
const a11y_poll_ms: c_uint = 30;

fn quit(ctx: *anyopaque) void {
    const self = selfOf(ctx);
    if (self.main_loop) |loop| ffi.g_main_loop_quit(loop);
}

fn createWindow(ctx: *anyopaque, id: u32, opts: backend.WindowOptions) errors.WindowError!void {
    const self = selfOf(ctx);
    const app = self.app orelse return errors.WindowError.InvalidWindow;
    return windows.create(app, id, opts) catch |e| switch (e) {
        error.OutOfMemory => errors.WindowError.OutOfMemory,
        error.InvalidArgument => errors.WindowError.InvalidArgument,
        else => errors.WindowError.NotSupported,
    };
}

fn destroyWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    windows.destroy(id);
}

fn showWindow(ctx: *anyopaque, id: u32, visible: bool) void {
    _ = ctx;
    windows.show(id, visible);
}

fn focusWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    windows.focus(id);
}

fn setBounds(ctx: *anyopaque, id: u32, r: backend.Rect) errors.WindowError!void {
    _ = ctx;
    if (!windows.setBounds(id, r)) return errors.WindowError.InvalidArgument;
}

fn getBounds(ctx: *anyopaque, id: u32) ?backend.Rect {
    _ = ctx;
    return windows.getBounds(id);
}

fn setTitle(ctx: *anyopaque, id: u32, title: []const u8) void {
    _ = ctx;
    windows.setTitle(id, title);
}

fn setState(ctx: *anyopaque, id: u32, state: events.WindowState) errors.WindowError!void {
    _ = ctx;
    if (!windows.setState(id, state)) return errors.WindowError.InvalidWindow;
}

fn setAlwaysOnTop(ctx: *anyopaque, id: u32, on: bool) void {
    _ = ctx;
    windows.setAlwaysOnTop(id, on);
}

fn setFullscreen(ctx: *anyopaque, id: u32, on: bool) errors.WindowError!void {
    _ = ctx;
    if (!windows.setFullscreen(id, on)) return errors.WindowError.InvalidWindow;
}

fn loadUrl(ctx: *anyopaque, id: u32, url: []const u8) errors.WindowError!void {
    _ = ctx;
    if (!webview.loadUrl(id, url)) return errors.WindowError.InvalidWindow;
}

fn evalJs(ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void {
    _ = ctx;
    if (!webview.eval(id, code)) return errors.WindowError.InvalidWindow;
}

fn injectScript(ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void {
    _ = ctx;
    if (!webview.inject(id, code)) return errors.WindowError.InvalidWindow;
}

/// Builds the window's menu bar from the portable description.
fn setMenu(ctx: *anyopaque, id: u32, m: @import("../../menu.zig").Menu) errors.WindowError!void {
    const self = selfOf(ctx);
    return windows.attachMenu(self.allocator(), id, m);
}

fn reportTrayClick(ctx: *anyopaque, _: []const u8) void {
    const self = selfOf(ctx);
    const app = self.app orelse return;
    // The tray is a single icon, so its click has one id.
    app.sink().trayClicked(1);
}

fn reportMenuCommand(ctx: *anyopaque, id: []const u8) void {
    const self = selfOf(ctx);
    const app = self.app orelse return;
    app.sink().menuCommand(id);
}

fn openDevtools(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    webview.openDevtools(id);
}

fn monitors(ctx: *anyopaque, out: []backend.MonitorInfo) usize {
    _ = ctx;
    return windows.monitors(out);
}

fn systemTheme(ctx: *anyopaque) events.Theme {
    _ = ctx;
    return windows.systemTheme();
}

fn wake(ctx: *anyopaque) void {
    _ = ctx;
    dispatch.wake();
}

fn requestFrame(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    windows.requestFrame(id);
}

fn presentFrame(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    windows.present(id);
}

test "linux backend exposes a complete vtable" {
    const vt = vtable();
    try std.testing.expect(@intFromPtr(vt.init) != 0);
    try std.testing.expect(@intFromPtr(vt.run) != 0);
}

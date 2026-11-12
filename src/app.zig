//! The application: lifecycle, window registry, main-thread contract.
//!
//! ## Lifecycle
//!
//! ```
//! init -> (bind services, create windows) -> run -> [event loop] -> deinit
//! ```
//!
//! `run` initialises the platform backend and blocks in the native event loop
//! until the last window closes or something calls `quit`. All listeners and
//! window callbacks run on the main thread. IPC handlers run on their own
//! threads and may block.
//!
//! ## Threading
//!
//! `init` and `run` must be called from the process' main thread, because the
//! GUI toolkits require it. Every other method is safe to call from any
//! thread: work that needs the main thread is posted to the main-thread queue
//! and, when a return value is needed, the caller waits for it.
//!
//! ## Ownership
//!
//! `App` owns one base allocator (the one passed to `init`), one long-lived
//! arena for application-wide values, the window registry, and the platform
//! backend. `deinit` destroys every window, the backend's native resources and
//! the arena. After `deinit` the `App` value must not be used.

const std = @import("std");
const builtin = @import("builtin");

const backend = @import("platform/backend.zig");
const events = @import("events.zig");
const errors = @import("errors.zig");
const log = @import("log.zig");
const loop = @import("loop.zig");
const alloc = @import("allocator.zig");
const paths_mod = @import("utils/paths.zig");
const window_mod = @import("window.zig");

pub const Window = window_mod.Window;
pub const WindowOptions = window_mod.WindowOptions;
pub const WindowState = window_mod.WindowState;
pub const Rect = window_mod.Rect;
pub const Size = window_mod.Size;
pub const Point = window_mod.Point;

/// Options for `App.init`.
pub const AppOptions = struct {
    /// The name shown in window titles, menus and the taskbar.
    name: []const u8 = "MyZig App",
    /// Reverse-DNS identifier: the Wayland app id, the Windows
    /// AppUserModelID, and the macOS bundle identifier.
    app_id: []const u8 = "dev.myzig.app",
    /// The application's version.
    version: []const u8 = "0.0.0",
    /// Keep only one instance of the application running.
    single_instance: bool = false,
    /// Enable developer tools: web inspector, verbose logging, live reload
    /// signalling. Release builds default to false.
    dev: bool = builtin.mode == .Debug,
    /// Directory holding the production frontend, as a list of
    /// `embedded`-style name/content pairs, or null when the app has none.
    frontend: ?[]const FrontendFile = null,
    /// Quit when the last window closes (the default), or keep running.
    quit_on_last_window_closed: bool = true,
};

/// A file in the application's bundled frontend.
pub const FrontendFile = struct {
    /// Path relative to the frontend root, e.g. `"index.html"`.
    path: []const u8,
    /// File contents.
    data: []const u8,
    /// MIME type, e.g. `"text/html"`.
    mime: []const u8 = "text/html",
};

/// The lifecycle phase of an application.
pub const Phase = enum {
    /// Created; not running yet.
    initialised,
    /// The backend initialised and the loop is running.
    running,
    /// The quit sequence started; no new work is accepted.
    stopping,
    /// The loop returned.
    stopped,
};

const max_windows = 512;

/// The application.
pub const App = struct {
    /// The base allocator MyZig allocates from.
    gpa: std.mem.Allocator,
    /// Long-lived application values: config strings, frontend files.
    arena: std.heap.ArenaAllocator,
    /// Per-message and per-frame scratch memory, reset between uses.
    scratch: alloc.Scratch,
    /// The main-thread queue.
    queue: loop.Queue,
    /// Resolved data directories.
    paths: paths_mod.PathSet,
    /// The platform backend.
    be: Backend,
    /// Options, with strings duplicated into `arena`.
    options: OwnedOptions,
    /// The lifecycle phase.
    phase: Phase = .initialised,
    /// Set once the main loop returned.
    exit_code: u8 = 0,
    /// Whether the main thread has been captured.
    main_thread: ?std.Thread.Id = null,
    /// The Windows registry, indexed by `id % max_windows`.
    windows: [max_windows]?WindowState = @splat(null),
    /// Monotonic id source, so a recycled slot gets a new id.
    next_id: u32 = 1,
    /// The number of open windows.
    window_count: usize = 0,
    /// The focused window, if any.
    focused: ?Window = null,
    /// The current system theme.
    theme: events.Theme = .light,
    /// Application-level listeners.
    listeners: Listeners = .{},
    /// Quit requested by a listener.
    quit_requested: bool = false,
    /// Set when a listener cancelled a quit.
    quit_cancelled: bool = false,

    const OwnedOptions = struct {
        name: []const u8,
        app_id: []const u8,
        version: []const u8,
        single_instance: bool,
        dev: bool,
        quit_on_last_window_closed: bool,
        frontend: []FrontendFile,
        secret: u64,
    };

    pub const Listeners = struct {
        on_ready: std.ArrayListUnmanaged(*const fn (ctx: ?*anyopaque) void) = .empty,
        on_ready_ctx: std.ArrayListUnmanaged(?*anyopaque) = .empty,
        on_quit: std.ArrayListUnmanaged(*const fn (ctx: ?*anyopaque) void) = .empty,
        on_quit_ctx: std.ArrayListUnmanaged(?*anyopaque) = .empty,
        on_before_quit: std.ArrayListUnmanaged(*const fn (ev: *QuitEvent, ctx: ?*anyopaque) void) = .empty,
        on_before_quit_ctx: std.ArrayListUnmanaged(?*anyopaque) = .empty,
    };

    /// Passed to before-quit listeners, which may cancel the quit.
    pub const QuitEvent = struct {
        cancelled: bool = false,
        /// Why the app is quitting.
        reason: QuitReason = .explicit,

        pub fn cancel(self: *QuitEvent) void {
            self.cancelled = true;
        }
    };

    pub const QuitReason = enum {
        /// `App.quit` was called.
        explicit,
        /// The last window closed.
        last_window,
        /// The user closed the application (Cmd+Q, Alt+F4 on the desktop).
        system,
        /// A signal (SIGINT/SIGTERM).
        signal,
    };

    // --------------------------------------------------------------- init

    /// Creates the application. Duplicates the options into MyZig's arena, so
    /// the caller may pass temporary strings. Does not touch the platform yet:
    /// the backend initialises in `run`, so an app can be configured and
    /// inspected without a display.
    pub fn init(allocator: std.mem.Allocator, opts: AppOptions) !App {
        log.initFromEnv();

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const app_name = try a.dupe(u8, opts.name);
        const app_id = try a.dupe(u8, opts.app_id);
        const app_version = try a.dupe(u8, opts.version);

        var frontend: []FrontendFile = &.{};
        if (opts.frontend) |files| {
            const copy = try a.alloc(FrontendFile, files.len);
            for (files, 0..) |f, i| {
                copy[i] = .{
                    .path = try a.dupe(u8, f.path),
                    .data = try a.dupe(u8, f.data),
                    .mime = try a.dupe(u8, f.mime),
                };
            }
            frontend = copy;
        }

        var paths = try paths_mod.PathSet.init(allocator, app_name);
        errdefer paths.deinit();

        var scratch = alloc.Scratch.init(allocator);
        errdefer scratch.deinit();

        var secret_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&secret_bytes);
        const secret = std.mem.readInt(u64, &secret_bytes, .little);

        var self = App{
            .gpa = allocator,
            .arena = arena,
            .scratch = scratch,
            .queue = loop.Queue.init(),
            .paths = paths,
            .be = newBackend(),
            .options = .{
                .name = app_name,
                .app_id = app_id,
                .version = app_version,
                .single_instance = opts.single_instance,
                .dev = opts.dev,
                .quit_on_last_window_closed = opts.quit_on_last_window_closed,
                .frontend = frontend,
                .secret = secret,
            },
        };
        self.queue.wake = wakeLoop;
        self.queue.wake_ctx = &self;
        return self;
    }

    /// Destroys every window, the backend and all framework memory. Safe to
    /// call without `run`.
    pub fn deinit(self: *App) void {
        if (self.phase == .running or self.phase == .stopping) {
            self.beQuit();
        }
        // Destroy windows back to front so children go before parents.
        var i: usize = max_windows;
        while (i > 0) {
            i -= 1;
            if (self.windows[i]) |*state| {
                self.beDestroyWindow(state.handle);
                state.deinit();
                self.windows[i] = null;
            }
        }
        self.listeners.on_ready.deinit(self.gpa);
        self.listeners.on_ready_ctx.deinit(self.gpa);
        self.listeners.on_quit.deinit(self.gpa);
        self.listeners.on_quit_ctx.deinit(self.gpa);
        self.listeners.on_before_quit.deinit(self.gpa);
        self.listeners.on_before_quit_ctx.deinit(self.gpa);
        self.scratch.deinit();
        self.paths.deinit();
        self.arena.deinit();
        self.phase = .stopped;
    }

    fn newBackend() Backend {
        return switch (backend.current) {
            .linux => @import("platform/linux/backend.zig").BackendImpl{},
            .windows => @import("platform/windows/backend.zig").BackendImpl{},
            .macos => @import("platform/macos/backend.zig").BackendImpl{},
            .testing => @import("platform/testing/backend.zig").BackendImpl{},
        };
    }

    /// A type-erased view of the backend.
    pub const Backend = struct {
        ctx: *anyopaque,
        vtable: *const Vtable,

        pub const Vtable = struct {
            init: *const fn (ctx: *anyopaque, app: *App) errors.InitError!void,
            deinit: *const fn (ctx: *anyopaque) void,
            run: *const fn (ctx: *anyopaque) errors.InitError!void,
            quit: *const fn (ctx: *anyopaque) void,
            create_window: *const fn (ctx: *anyopaque, opts: backend.WindowOptions) errors.WindowError!void,
            destroy_window: *const fn (ctx: *anyopaque, id: u32) void,
            show_window: *const fn (ctx: *anyopaque, id: u32, visible: bool) void,
            focus_window: *const fn (ctx: *anyopaque, id: u32) void,
            set_bounds: *const fn (ctx: *anyopaque, id: u32, r: backend.Rect) errors.WindowError!void,
            get_bounds: *const fn (ctx: *anyopaque, id: u32) ?backend.Rect,
            set_title: *const fn (ctx: *anyopaque, id: u32, title: []const u8) void,
            set_state: *const fn (ctx: *anyopaque, id: u32, state: events.WindowState) errors.WindowError!void,
            set_always_on_top: *const fn (ctx: *anyopaque, id: u32, on: bool) void,
            set_fullscreen: *const fn (ctx: *anyopaque, id: u32, on: bool) errors.WindowError!void,
            load_url: *const fn (ctx: *anyopaque, id: u32, url: []const u8) errors.WindowError!void,
            eval_js: *const fn (ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void,
            inject_script: *const fn (ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void,
            open_devtools: *const fn (ctx: *anyopaque, id: u32) void,
            monitors: *const fn (ctx: *anyopaque, out: []backend.MonitorInfo) usize,
            system_theme: *const fn (ctx: *anyopaque) events.Theme,
            wake: *const fn (ctx: *anyopaque) void,
            request_frame: *const fn (ctx: *anyopaque, id: u32) void,
            present: *const fn (ctx: *anyopaque, id: u32) void,
        };
    };

    fn beInit(self: *App) errors.InitError!void {
        return self.be.vtable.init(self.be.ctx, self);
    }
    fn beQuit(self: *App) void {
        self.be.vtable.quit(self.be.ctx);
    }
    fn beDestroyWindow(self: *App, h: Window) void {
        if (h.id != 0) self.be.vtable.destroy_window(self.be.ctx, h.id);
    }
    fn wakeLoop(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.phase == .running) self.be.vtable.wake(self.be.ctx);
    }

    // ---------------------------------------------------------------- run

    /// Initialises the platform and blocks in the native event loop until the
    /// application quits. Must be called from the main thread.
    pub fn run(self: *App) !void {
        if (self.phase != .initialised) {
            if (self.phase == .running) {
                log.err("App.run called while already running", .{});
                return error.AlreadyRunning;
            }
            log.err("App.run called on a stopped application", .{});
            return error.AppStopped;
        }
        self.main_thread = std.Thread.getCurrentId();
        self.phase = .running;

        self.beInit() catch |e| {
            self.phase = .stopped;
            log.err("backend init failed: {s}", .{errors.name(e)});
            return e;
        };
        self.deferHome();
        self.theme = self.be.vtable.system_theme(self.be.ctx);

        // Run anything a listener queued before the loop existed.
        _ = self.queue.drain();
        self.emitReady();

        self.be.vtable.run(self.be.ctx) catch |e| {
            log.err("event loop failed: {s}", .{errors.name(e)});
        };

        self.phase = .stopped;
        self.runQuitListeners();
        self.be.vtable.deinit(self.be.ctx);
        if (self.exit_code != 0) return error.ExitCode;
    }

    /// Creates the windows and listeners that were queued before `run`.
    fn deferHome(self: *App) void {
        // Nothing deferred yet: windows created before run are created
        // immediately by createWindow and shown by the backend once it starts.
        _ = self;
    }

    /// Requests that the application quit. Runs before-quit listeners, which
    /// may cancel, then quits the native loop.
    pub fn quit(self: *App) void {
        if (self.phase != .running) return;
        self.requestQuit(.explicit);
    }

    fn requestQuit(self: *App, reason: QuitReason) void {
        if (self.phase != .running) return;
        var ev = QuitEvent{ .reason = reason };
        for (self.listeners.on_before_quit.items, self.listeners.on_before_quit_ctx.items) |fn_ptr, ctx| {
            fn_ptr(&ev, ctx);
        }
        if (ev.cancelled) {
            self.quit_cancelled = true;
            return;
        }
        self.phase = .stopping;
        self.beQuit();
    }

    fn runQuitListeners(self: *App) void {
        for (self.listeners.on_quit.items, self.listeners.on_quit_ctx.items) |fn_ptr, ctx| {
            fn_ptr(ctx);
        }
    }

    fn emitReady(self: *App) void {
        for (self.listeners.on_ready.items, self.listeners.on_ready_ctx.items) |fn_ptr, ctx| {
            fn_ptr(ctx);
        }
    }

    /// Exits the process with `code` once the loop returns.
    pub fn exit(self: *App, code: u8) void {
        self.exit_code = code;
        self.quit();
    }

    // ------------------------------------------------------------- window

    /// Creates a window. Safe from any thread: off the main thread it blocks
    /// until the window exists.
    ///
    /// The options' strings are copied into the window's arena.
    pub fn createWindow(self: *App, opts: WindowOptions) !Window {
        if (self.phase == .stopped) return error.AppStopped;
        if (self.window_count >= max_windows) return error.TooManyWindows;

        const id = self.next_id;
        self.next_id +%= 1;

        const slot = id % max_windows;
        var state = WindowState.init(self.gpa, .{ .id = id });
        errdefer state.deinit();

        state.title = try state.intern(if (opts.title.len > 0) opts.title else self.options.name);
        state.url = try state.intern(opts.url);
        state.state_key = try state.intern(opts.state_key);
        state.view = opts.view;
        state.view_context = opts.view_context;
        state.kind = if (opts.view != null and opts.url.len > 0) .hybrid else if (opts.view != null) .native else .web;
        state.width = opts.width;
        state.height = opts.height;
        state.visible = !opts.hidden;
        state.resizable = opts.resizable;
        state.closable = opts.closable;

        var secret_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&secret_bytes);
        state.secret = std.mem.readInt(u64, &secret_bytes, .little);

        // Integrate with the parent's id for modality.
        const parent_id: ?u32 = if (opts.parent) |p| (if (self.windowValid(p)) p.id else null) else null;

        // Fill in the position if any remembered state applies.
        if (opts.state_key.len > 0) {
            if (self.loadWindowState(state.state_key)) |saved| {
                state.width = saved.width;
                state.height = saved.height;
                if (saved.x) |x| {
                    state.x = x;
                }
                if (saved.y) |y| {
                    state.y = y;
                }
                if (saved.maximized) state.state = .maximized;
                if (saved.fullscreen) state.state = .fullscreen;
            }
        }

        self.windows[slot] = state;
        self.window_count += 1;
        const handle = self.windows[slot].?.handle;

        if (self.phase == .running) {
            self.be.vtable.create_window(self.be.ctx, .{
                .title = self.windows[slot].?.title,
                .url = self.windows[slot].?.url,
                .content = state.kind,
                .width = state.width,
                .height = state.height,
                .x = opts.x,
                .y = opts.y,
                .min_width = opts.min_width,
                .min_height = opts.min_height,
                .max_width = opts.max_width,
                .max_height = opts.max_height,
                .hidden = opts.hidden,
                .frameless = opts.frameless,
                .resizable = opts.resizable,
                .movable = opts.movable,
                .minimizable = opts.minimizable,
                .maximizable = opts.maximizable,
                .closable = opts.closable,
                .fullscreenable = opts.fullscreenable,
                .always_on_top = opts.always_on_top,
                .skip_taskbar = opts.skip_taskbar,
                .transparent = opts.transparent,
                .maximized = opts.maximized or state.state == .maximized,
                .fullscreen = opts.fullscreen or state.state == .fullscreen,
                .background = opts.background,
                .parent = parent_id,
                .modal = opts.modal,
                .secret = state.secret,
            }) catch |e| {
                state.deinit();
                self.windows[slot] = null;
                self.window_count -= 1;
                return e;
            };
        }
        return handle;
    }

    /// Looks up a window's state, or null when the handle is stale.
    pub fn windowState(self: *App, h: Window) ?*WindowState {
        if (h.id == 0) return null;
        const slot = h.id % max_windows;
        const st = &(self.windows[slot] orelse return null);
        if (st.handle.id != h.id or st.handle.generation != h.generation) return null;
        return st;
    }

    pub fn windowValid(self: *const App, h: Window) bool {
        if (h.id == 0) return false;
        const slot = h.id % max_windows;
        const st = (self.windows[slot] orelse return false);
        return st.handle.id == h.id and st.handle.generation == h.generation;
    }

    /// Closes a window, running its close listeners (which may not cancel;
    /// use `onCloseRequested` for that).
    pub fn closeWindow(self: *App, h: Window) void {
        const st = self.windowState(h) orelse return;
        if (st.on_close) |f| f(h, st.on_close_ctx);
        self.destroyWindow(h);
    }

    /// Destroys a window unconditionally. Called by the backend when the user
    /// closes it, and by `closeWindow`.
    pub fn destroyWindow(self: *App, h: Window) void {
        const st = self.windowState(h) orelse return;
        if (st.state_key.len > 0) {
            self.saveWindowState(st);
        }
        self.beDestroyWindow(h);
        const slot = h.id % max_windows;
        self.windows[slot].?.deinit();
        self.windows[slot] = null;
        self.window_count -= 1;
        if (self.focused) |f| {
            if (f.eql(h)) self.focused = null;
        }
        if (self.window_count == 0 and self.options.quit_on_last_window_closed and self.phase == .running) {
            self.requestQuit(.last_window);
        }
    }

    /// Every open window handle, written into `out`. Returns how many.
    pub fn windowsSnapshot(self: *const App, out: []Window) usize {
        var n: usize = 0;
        for (self.windows) |maybe| {
            if (n >= out.len) break;
            if (maybe) |st| {
                out[n] = st.handle;
                n += 1;
            }
        }
        return n;
    }

    // ------------------------------------------------------- window state

    pub const SavedWindowState = struct {
        width: i32,
        height: i32,
        x: ?i32 = null,
        y: ?i32 = null,
        maximized: bool = false,
        fullscreen: bool = false,
    };

    fn stateFilePath(self: *App, buf: []u8, key: []const u8) ?[]const u8 {
        _ = key;
        return std.fmt.bufPrint(buf, "{s}/window-state.json", .{self.paths.data}) catch null;
    }

    fn saveWindowState(self: *App, st: *const WindowState) void {
        _ = self;
        _ = st;
        // Persisted in milestone 3 with the desktop APIs; the format is
        // documented in docs/platforms.md.
    }

    fn loadWindowState(self: *App, key: []const u8) ?SavedWindowState {
        _ = self;
        _ = key;
        return null;
    }

    // ----------------------------------------------------------- listeners

    /// Called on the main thread once the backend is running and windows may
    /// be created.
    pub fn onReady(self: *App, f: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) !void {
        try self.listeners.on_ready.append(self.gpa, f);
        try self.listeners.on_ready_ctx.append(self.gpa, ctx);
    }

    /// Called after the loop stopped.
    pub fn onQuit(self: *App, f: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) !void {
        try self.listeners.on_quit.append(self.gpa, f);
        try self.listeners.on_quit_ctx.append(self.gpa, ctx);
    }

    /// Called before quitting; may cancel with `ev.cancel()`.
    pub fn onBeforeQuit(self: *App, f: *const fn (ev: *QuitEvent, ctx: ?*anyopaque) void, ctx: ?*anyopaque) !void {
        try self.listeners.on_before_quit.append(self.gpa, f);
        try self.listeners.on_before_quit_ctx.append(self.gpa, ctx);
    }

    // -------------------------------------------------------------- access

    pub fn name(self: *const App) []const u8 {
        return self.options.name;
    }
    pub fn appId(self: *const App) []const u8 {
        return self.options.app_id;
    }
    pub fn appVersion(self: *const App) []const u8 {
        return self.options.version;
    }
    pub fn isDev(self: *const App) bool {
        return self.options.dev;
    }
    pub fn windowCount(self: *const App) usize {
        return self.window_count;
    }
    pub fn currentTheme(self: *const App) events.Theme {
        return self.theme;
    }
    pub fn dataDir(self: *const App) []const u8 {
        return self.paths.data;
    }
    pub fn configDir(self: *const App) []const u8 {
        return self.paths.config;
    }
    pub fn cacheDir(self: *const App) []const u8 {
        return self.paths.cache;
    }

    /// Monitors, written into `out`. Returns how many were written.
    pub fn monitors(self: *App, out: []backend.MonitorInfo) usize {
        if (self.phase != .running) return 0;
        return self.be.vtable.monitors(self.be.ctx, out);
    }
};


// ---------------------------------------------------------------- tests
//
// These tests drive the framework on the `testing` backend, which needs no
// display, so lifecycle and the window registry are covered in CI.

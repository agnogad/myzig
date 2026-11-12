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
const env = @import("utils/env.zig");
const ipc_mod = @import("ipc/ipc.zig");
const desktop_mod = @import("platform/desktop.zig");
const menu_mod = @import("menu.zig");
const json = @import("json.zig");
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
    dev: bool = builtin.mode == .debug,
    /// Directory holding the production frontend, as a list of
    /// `embedded`-style name/content pairs, or null when the app has none.
    frontend: ?[]const FrontendFile = null,
    /// Quit when the last window closes (the default), or keep running.
    quit_on_last_window_closed: bool = true,
};

/// A file in the application's bundled frontend.
/// Where a window points when the app embeds a frontend and the window does not
/// name a URL of its own.
pub const default_frontend_url = "myzig://app/index.html";

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

/// A type-erased handler for a press on a native surface.
const SurfaceInput = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, id: u32, x: f32, y: f32) bool,
};

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
    /// The platform backend, type erased.
    be: Backend,
    /// The backend implementation, stored by value inside the App so `be.ctx`
    /// has a stable address for the app's lifetime. `App` is returned by value
    /// from `init`, so the address is fixed up once in `run`.
    be_storage: BackendStorage = undefined,
    /// Options, with strings duplicated into `arena`.
    options: OwnedOptions,
    /// The native-surface press handler, when the application installed one.
    surface_input: ?SurfaceInput = null,
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
    /// The typed IPC layer: services, subscriptions and in-flight cancels.
    ipc: ipc_mod.Exchange,
    /// Storage for the built-in service definitions. The registry keeps
    /// pointers into this array, so it must live as long as the app.
    builtin_methods: [ipc_mod.builtin.count]ipc_mod.service.Method,

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

        // A per-process secret the page bridge must present, so a page cannot
        // forge calls on behalf of another window.
        var secret_bytes: [8]u8 = undefined;
        env.secureRandom(&secret_bytes);
        const secret = std.mem.readInt(u64, &secret_bytes, .little);

        var self = App{
            .gpa = allocator,
            .arena = arena,
            .scratch = scratch,
            .queue = loop.Queue.init(),
            .paths = paths,
            .be = .{ .ctx = undefined, .vtable = &backend_vtable },
            .be_storage = newBackend(),
            .ipc = ipc_mod.Exchange.init(allocator),
            .builtin_methods = undefined,
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

        // The built-in services make the bridge's `clipboard`, `dialog`,
        // `notify` and `openExternal` work without the application binding
        // anything. Registration happens here, after `self` exists, because
        // every handler receives the app as its context.
        ipc_mod.builtin.fill(&self.builtin_methods, &self);
        _ = self.bindAll(&self.builtin_methods) catch |e| {
            // A duplicate here is a framework bug, not a user error, so it is
            // reported and the app still starts.
            log.err("built-in service registration failed: {s}", .{@errorName(e)});
        };
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
        self.ipc.deinit();
        self.paths.deinit();
        self.arena.deinit();
        self.phase = .stopped;
    }

    /// Every backend implementation, present in this build only for the
    /// selected platform: a union of the one that applies.
    pub const BackendStorage = switch (backend.current) {
        .linux => @import("platform/linux/backend.zig").BackendImpl,
        .windows => @import("platform/windows/backend.zig").BackendImpl,
        .macos => @import("platform/macos/backend.zig").BackendImpl,
        .testing => @import("platform/testing/backend.zig").BackendImpl,
    };

    fn newBackend() BackendStorage {
        return .{};
    }

    /// Points `be` at this App's own storage. Called once, before the backend
    /// initialises, because `App` moves when `init` returns it.
    fn bindBackend(self: *App) void {
        self.be = .{
            .ctx = @ptrCast(&self.be_storage),
            .vtable = &backend_vtable,
        };
        // Replies and events reach the page through the same backend call the
        // application uses for `eval`, so the IPC layer never touches a
        // platform handle.
        self.ipc.attach(.{
            .ctx = self,
            .eval = evalForIpc,
        });

        // `init` returns the app by value, so it lands in a new location when
        // the caller stores it. Every built-in handler holds the address it was
        // created with, which would be the discarded copy; rebinding here
        // points them at the real app.
        ipc_mod.builtin.setApp(self);
    }

    fn evalForIpc(ctx: ?*anyopaque, window: u32, code: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (self.phase != .running) return false;
        const slot = window % max_windows;
        if (self.windows[slot] == null) return false;
        self.be.vtable.eval_js(self.be.ctx, window, code) catch return false;
        return true;
    }

    /// Registers a callable method. Generated glue calls this once per method
    /// at startup; a duplicate name is a programming error and returns
    /// `error.DuplicateName`.
    pub fn bind(self: *App, method: ipc_mod.service.Method) !void {
        try self.ipc.registry.add(method);
    }

    /// Registers every method in a slice, for generated glue.
    pub fn bindAll(self: *App, methods: []const ipc_mod.service.Method) !void {
        try self.ipc.registry.addAll(methods);
    }

    // -------------------------------------------------------- desktop APIs

    /// Reads the clipboard into a caller-provided buffer. Null when the
    /// clipboard is empty or holds something other than text.
    pub fn readClipboard(self: *App, buf: []u8) ?[]const u8 {
        if (self.phase != .running) return null;
        return desktop_backend.readClipboard(buf);
    }

    /// Puts text on the clipboard. Returns false when the platform refused.
    pub fn writeClipboard(self: *App, text: []const u8) bool {
        if (self.phase != .running) return false;
        return desktop_backend.writeClipboard(text);
    }

    /// Shows a file dialog. Blocks the main thread until the user answers,
    /// which is the behaviour a page's `await` expects.
    pub fn fileDialog(
        self: *App,
        opts: desktop_mod.FileDialogOptions,
        out: *const desktop_mod.PathBuffer,
    ) desktop_mod.FileDialogError!desktop_mod.FileChoice {
        if (self.phase != .running) return error.NotSupported;
        return desktop_backend.fileDialog(opts, out);
    }

    /// Shows a message box and returns the index of the button pressed, or null
    /// when it was dismissed.
    pub fn messageBox(self: *App, opts: desktop_mod.MessageOptions) ?usize {
        if (self.phase != .running) return null;
        return desktop_backend.messageBox(opts);
    }

    /// Shows a notification. Returns false when the desktop refused it.
    pub fn notify(self: *App, opts: desktop_mod.NotificationOptions) bool {
        if (self.phase != .running) return false;
        return desktop_backend.notify(opts);
    }

    /// Opens a URL in the user's browser.
    pub fn openExternal(self: *App, url: []const u8) bool {
        if (self.phase != .running) return false;
        return desktop_backend.openExternal(url);
    }

    /// A view over the desktops the selected backend provides.
    fn desktopOf(self: *App) desktop_mod.Desktop {
        if (self.phase != .running) {
            return .{ .ctx = null, .vtable = &inert_desktop };
        }
        return switch (backend.current) {
            .linux => .{ .ctx = null, .vtable = &@import("platform/linux/desktop.zig").vtable() },
            else => .{ .ctx = null, .vtable = &inert_desktop },
        };
    }

    /// Every desktop method says "not supported", so a call before `run` or on
    /// a backend without the feature has one predictable behaviour.
    const inert_desktop = desktop_mod.Desktop.VTable{
        .read_clipboard = struct {
            fn f(_: ?*anyopaque, _: []u8) ?[]const u8 {
                return null;
            }
        }.f,
        .write_clipboard = struct {
            fn f(_: ?*anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
        .file_dialog = struct {
            fn f(_: ?*anyopaque, _: desktop_mod.FileDialogOptions, _: *const desktop_mod.PathBuffer) desktop_mod.FileDialogError!desktop_mod.FileChoice {
                return error.NotSupported;
            }
        }.f,
        .message_box = struct {
            fn f(_: ?*anyopaque, _: desktop_mod.MessageOptions) ?usize {
                return null;
            }
        }.f,
        .notify = struct {
            fn f(_: ?*anyopaque, _: desktop_mod.NotificationOptions) bool {
                return false;
            }
        }.f,
        .open_external = struct {
            fn f(_: ?*anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
        .show_in_folder = struct {
            fn f(_: ?*anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
        .theme = struct {
            fn f(_: ?*anyopaque) desktop_mod.Theme {
                return .light;
            }
        }.f,
    };

    /// The vtable for this build, held in a named constant so its address is
    /// stable: taking the address of a temporary is what made every desktop
    /// call fall through to the inert table.
    const desktop_vtable: desktop_mod.Desktop.VTable = switch (backend.current) {
        .linux => @import("platform/linux/desktop.zig").vtable(),
        else => App.inert_desktop,
    };
    const desktop_backend: desktop_mod.Desktop = .{
        .ctx = null,
        .vtable = &desktop_vtable,
    };

    // ---------------------------------------------------------------- tray

    /// Shows a tray icon from a themed icon name. Returns false when the
    /// desktop has no status area, which is a real limitation: the application
    /// should fall back to a window.
    pub fn createTray(self: *App, icon_name: []const u8, tooltip: []const u8) bool {
        if (self.phase != .running) return false;
        return switch (backend.current) {
            .linux => @import("platform/linux/gtray.zig").create(self.gpa, icon_name, tooltip),
            else => false,
        };
    }

    /// Removes the tray icon, if any.
    pub fn destroyTray(self: *App) void {
        if (self.phase != .running) return;
        switch (backend.current) {
            .linux => @import("platform/linux/gtray.zig").destroy(),
            else => {},
        }
    }

    /// Binds a global accelerator, which fires while any application has focus.
    ///
    /// Fails with `error.NotSupported` on a session that forbids global grabs
    /// and `error.AlreadyTaken` when another client holds the same combination.
    /// The failure is reported rather than swallowed: an unbound shortcut is
    /// indistinguishable from a broken one.
    pub fn registerShortcut(self: *App, accel: []const u8) !void {
        const parsed = menu_mod.Accelerator.parse(accel) catch return error.InvalidAccelerator;
        if (self.phase != .running) return error.NotRunning;
        return switch (backend.current) {
            .linux => @import("platform/linux/gtray.zig").registerShortcut(self.gpa, .{
                .accel = parsed,
                .text = accel,
            }),
            else => error.NotSupported,
        };
    }

    // ---------------------------------------------------------------- menu

    /// Attaches a menu bar to a window. The menu is copied into the window's
    /// state, so the caller does not need to keep it alive.
    /// Installs the handler for pointer presses on native surfaces. `handler`
    /// receives window id and position in DIPs.
    pub fn setSurfaceInput(
        self: *App,
        comptime T: type,
        ctx: *T,
        handler: *const fn (state: *T, x: f32, y: f32) bool,
    ) void {
        const Thunk = struct {
            state: *T,
            handler: *const fn (state: *T, x: f32, y: f32) bool,

            fn call(c: *anyopaque, id: u32, x: f32, y: f32) bool {
                _ = id;
                const self_: *@This() = @ptrCast(@alignCast(c));
                return self_.handler(self_.state, x, y);
            }
        };

        const thunk = self.arena.allocator().create(Thunk) catch return;
        thunk.* = .{ .state = ctx, .handler = handler };
        self.surface_input = .{ .ctx = @ptrCast(thunk), .call = Thunk.call };
    }

    pub fn setMenu(self: *App, h: Window, m: menu_mod.Menu) !void {
        if (!self.windowValid(h)) return error.InvalidWindow;
        const st = self.windowState(h) orelse return error.InvalidWindow;
        st.menu = m;
        if (self.phase == .running) try self.applyMenu(h);
    }

    /// Rebuilds a window's menu bar from the stored description.
    fn applyMenu(self: *App, h: Window) !void {
        const st = self.windowState(h) orelse return error.InvalidWindow;
        if (st.menu) |m| {
            self.be.vtable.set_menu(self.be.ctx, h.id, m) catch |e| {
                log.err("menu for window {d} could not be built: {s}", .{ h.id, @errorName(e) });
                return e;
            };
        }
    }

    /// Sends `payload` to every window subscribed to `name`. Returns the number
    /// of windows addressed.
    pub fn emit(self: *App, event: []const u8, payload: json.Value) usize {
        return self.ipc.emit(event, payload);
    }

    /// The vtable of the selected backend, resolved at comptime.
    const backend_vtable = switch (backend.current) {
        .linux => @import("platform/linux/backend.zig").vtable(),
        .windows => @import("platform/windows/backend.zig").vtable(),
        .macos => @import("platform/macos/backend.zig").vtable(),
        .testing => @import("platform/testing/backend.zig").vtable(),
    };

    /// A type-erased view of the backend.
    pub const Backend = struct {
        ctx: *anyopaque,
        vtable: *const Vtable,

        pub const Vtable = struct {
            init: *const fn (ctx: *anyopaque, app: *App) errors.InitError!void,
            deinit: *const fn (ctx: *anyopaque) void,
            run: *const fn (ctx: *anyopaque) errors.InitError!void,
            quit: *const fn (ctx: *anyopaque) void,
            create_window: *const fn (ctx: *anyopaque, id: u32, opts: backend.WindowOptions) errors.WindowError!void,
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
            set_menu: *const fn (ctx: *anyopaque, id: u32, m: menu_mod.Menu) errors.WindowError!void,
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

        // The App moved when `init` returned it, so the backend's context
        // pointer is bound here, in its final location.
        self.bindBackend();

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

    /// Materialises the windows the application created before `run`. They are
    /// made in creation order so the first one ends up on top.
    fn deferHome(self: *App) void {
        var id: u32 = 1;
        const last = self.next_id;
        while (id < last) : (id += 1) {
            const st = self.windows[id % max_windows] orelse continue;
            if (!st.pending_native) continue;
            self.createNativeWindow(id);
        }
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
        // A web or hybrid window with no explicit URL serves the frontend's
        // `index.html`. Without this the backend is asked to make a window with
        // nothing to show, which leaves it empty.
        state.url = try state.intern(if (opts.url.len > 0)
            opts.url
        else if (self.options.frontend.len > 0 and opts.view == null)
            default_frontend_url
        else
            "");
        state.state_key = try state.intern(opts.state_key);
        state.view = opts.view;
        state.view_context = opts.view_context;
        state.kind = if (opts.view != null and opts.url.len > 0) .hybrid else if (opts.view != null) .native else .web;
        state.width = opts.width;
        state.height = opts.height;
        state.visible = !opts.hidden;
        state.resizable = opts.resizable;
        state.closable = opts.closable;

        state.native_draw = opts.native_draw;

        var secret_bytes: [8]u8 = undefined;
        env.secureRandom(&secret_bytes);
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

        {
            const native = self.windows[slot].?.native;
            _ = &native;
        }
        self.windows[slot].?.native = .{
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
            .native_draw = self.windows[slot].?.native_draw,
        };

        if (self.phase == .running) {
            self.createNativeWindow(id);
        } else {
            // The platform is not up yet; `run` materialises it in order.
            self.windows[slot].?.pending_native = true;
        }
        return handle;
    }

    /// Asks the backend to create the native window for an existing framework
    /// window, and undoes the framework window if the backend refuses.
    fn createNativeWindow(self: *App, id: u32) void {
        const slot = id % max_windows;
        const st = &(self.windows[slot] orelse return);
        st.pending_native = false;
        self.be.vtable.create_window(self.be.ctx, id, st.native) catch |e| {
            log.err("cannot create window {d}: {s}", .{ id, errors.name(e) });
            const handle = st.handle;
            st.deinit();
            self.windows[slot] = null;
            self.window_count -= 1;
            _ = handle;
            return;
        };
        // A menu set before `run` is stored with the window and applied here,
        // once the native window exists to hang it on.
        self.applyMenu(st.handle) catch {};
    }

    /// Looks up a window's state, or null when the handle is stale.
    pub fn windowState(self: *App, h: Window) ?*WindowState {
        if (h.id == 0) return null;
        const slot = h.id % max_windows;
        const st = &(self.windows[slot] orelse return null);
        if (st.handle.id != h.id or st.handle.generation != h.generation) return null;
        return st;
    }

    /// Resolves a raw backend id back to its current handle. Used by built-in
    /// services, which only know the id of the window that called them.
    pub fn windowById(self: *const App, id: u32) ?Window {
        if (id == 0) return null;
        const st = (self.windows[id % max_windows] orelse return null);
        if (st.handle.id != id) return null;
        return st.handle;
    }

    pub fn windowValid(self: *const App, h: Window) bool {
        if (h.id == 0) return false;
        const slot = h.id % max_windows;
        const st = (self.windows[slot] orelse return false);
        return st.handle.id == h.id and st.handle.generation == h.generation;
    }

    /// Closes a window, running its close listeners (which may not cancel;
    /// use `onCloseRequested` for that).
    // --------------------------------------------------- window operations

    /// Shows or hides a window. A hidden window keeps its web view and state.
    pub fn showWindow(self: *App, h: Window, visible: bool) void {
        if (!self.windowValid(h)) return;
        self.be.vtable.show_window(self.be.ctx, h.id, visible);
    }

    /// Raises and focuses a window.
    pub fn focusWindow(self: *App, h: Window) void {
        if (!self.windowValid(h)) return;
        self.be.vtable.focus_window(self.be.ctx, h.id);
    }

    /// Changes the window title.
    pub fn setWindowTitle(self: *App, h: Window, title: []const u8) void {
        if (!self.windowValid(h)) return;
        self.be.vtable.set_title(self.be.ctx, h.id, title);
    }

    /// Moves and resizes a window in DIPs.
    pub fn setWindowBounds(self: *App, h: Window, r: backend.Rect) !void {
        if (!self.windowValid(h)) return error.InvalidWindow;
        try self.be.vtable.set_bounds(self.be.ctx, h.id, r);
    }

    /// The window's current frame in DIPs, or null when it is gone.
    pub fn windowBounds(self: *App, h: Window) ?backend.Rect {
        if (!self.windowValid(h)) return null;
        return self.be.vtable.get_bounds(self.be.ctx, h.id);
    }

    /// Applies a window state: normal, minimised, maximised or fullscreen.
    pub fn setWindowState(self: *App, h: Window, state: events.WindowState) !void {
        if (!self.windowValid(h)) return error.InvalidWindow;
        try self.be.vtable.set_state(self.be.ctx, h.id, state);
    }

    /// Keeps a window above the others.
    pub fn setWindowAlwaysOnTop(self: *App, h: Window, on: bool) void {
        if (!self.windowValid(h)) return;
        self.be.vtable.set_always_on_top(self.be.ctx, h.id, on);
    }

    /// Enters or leaves fullscreen.
    pub fn setWindowFullscreen(self: *App, h: Window, on: bool) !void {
        if (!self.windowValid(h)) return error.InvalidWindow;
        try self.be.vtable.set_fullscreen(self.be.ctx, h.id, on);
    }

    /// Loads a URL in the window's web view.
    pub fn loadWindowUrl(self: *App, h: Window, url: []const u8) !void {
        if (!self.windowValid(h)) return error.InvalidWindow;
        try self.be.vtable.load_url(self.be.ctx, h.id, url);
    }

    /// Evaluates JavaScript in the window's page. The result is discarded;
    /// use a service when the page needs an answer.
    pub fn evalInWindow(self: *App, h: Window, code: []const u8) !void {
        if (!self.windowValid(h)) return error.InvalidWindow;
        try self.be.vtable.eval_js(self.be.ctx, h.id, code);
    }

    /// Opens the developer tools for a window.
    pub fn openDevtools(self: *App, h: Window) void {
        if (!self.windowValid(h)) return;
        self.be.vtable.open_devtools(self.be.ctx, h.id);
    }

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

    // ----------------------------------------------------------- event sink
    //
    // The backend reports native events through this sink. Every callback runs
    // on the main thread, so the core needs no locks here. Events for windows
    // the core no longer knows are dropped.

    /// The sink the backend calls. Stable for the app's lifetime.
    pub fn sink(self: *App) backend.EventSink {
        return .{ .ctx = self, .vtable = &sink_vtable };
    }

    const sink_vtable = backend.EventSink.VTable{
        .ready = onBackendReady,
        .all_windows_closed = onAllWindowsClosed,
        .quitting = onBackendQuitting,
        .activate = onActivate,
        .deactivate = onDeactivate,
        .open_url = onOpenUrl,
        .open_file = onOpenFile,
        .window_created = onWindowCreated,
        .window_closed = onWindowClosed,
        .window_close_requested = onWindowCloseRequested,
        .window_focus = onWindowFocus,
        .window_resized = onWindowResized,
        .window_moved = onWindowMoved,
        .window_state_changed = onWindowStateChanged,
        .window_scale_changed = onWindowScaleChanged,
        .window_theme_changed = onWindowThemeChanged,
        .web_title_changed = onWebTitleChanged,
        .web_url_changed = onWebUrlChanged,
        .web_load_started = onWebLoadStarted,
        .web_load_finished = onWebLoadFinished,
        .web_load_failed = onWebLoadFailed,
        .web_dom_ready = onWebDomReady,
        .web_message = onWebMessage,
        .web_console = onWebConsole,
        .web_navigation_requested = onWebNavigationRequested,
        .surface_resized = onSurfaceResized,
        .surface_input = onSurfaceInput,
        .surface_frame_requested = onSurfaceFrameRequested,
        .menu_command = onMenuCommand,
        .notification_clicked = onNotificationClicked,
        .tray_clicked = onTrayClicked,
        .shortcut_pressed = onShortcutPressed,
        .theme_changed = onThemeChanged,
        .dispatch = onDispatch,
    };

    inline fn fromCtx(ctx: *anyopaque) *App {
        return @ptrCast(@alignCast(ctx));
    }

    fn onBackendReady(ctx: *anyopaque) void {
        fromCtx(ctx).emitReady();
    }
    fn onAllWindowsClosed(ctx: *anyopaque) void {
        const self = fromCtx(ctx);
        if (self.options.quit_on_last_window_closed) self.requestQuit(.last_window);
    }
    fn onBackendQuitting(ctx: *anyopaque) void {
        fromCtx(ctx).requestQuit(.system);
    }
    fn onActivate(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn onDeactivate(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn onOpenUrl(ctx: *anyopaque, url: []const u8) void {
        _ = ctx;
        log.info("open url: {s}", .{url});
    }
    fn onOpenFile(ctx: *anyopaque, path: []const u8) void {
        _ = ctx;
        log.info("open file: {s}", .{path});
    }
    fn onWindowCreated(ctx: *anyopaque, id: u32) void {
        const self = fromCtx(ctx);
        if (self.windowState(.{ .id = id })) |st| {
            st.visible = true;
        }
    }
    fn onWindowClosed(ctx: *anyopaque, id: u32) void {
        const self = fromCtx(ctx);
        // Drop the window's subscriptions before the handle disappears, so an
        // event cannot be addressed to a page that no longer exists.
        self.ipc.forgetWindow(id);
        self.destroyWindow(.{ .id = id });
    }
    fn onWindowCloseRequested(ctx: *anyopaque, id: u32) void {
        const self = fromCtx(ctx);
        self.closeWindow(.{ .id = id });
    }
    fn onWindowFocus(ctx: *anyopaque, id: u32, focused: bool) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.focused = focused;
        if (focused) {
            self.focused = st.handle;
        } else if (self.focused) |f| {
            if (f.id == id) self.focused = null;
        }
        if (st.on_focus) |f| f(st.handle, focused, st.on_focus_ctx);
    }
    fn onWindowResized(ctx: *anyopaque, id: u32, width: i32, height: i32) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.width = width;
        st.height = height;
        if (st.on_resize) |f| f(st.handle, .{ .width = width, .height = height }, st.on_resize_ctx);
    }
    fn onWindowMoved(ctx: *anyopaque, id: u32, x: i32, y: i32) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.x = x;
        st.y = y;
    }
    fn onWindowStateChanged(ctx: *anyopaque, id: u32, state: events.WindowState) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.state = state;
    }
    fn onWindowScaleChanged(ctx: *anyopaque, id: u32, scale: f32) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.scale = scale;
    }
    fn onWindowThemeChanged(ctx: *anyopaque, id: u32, theme: events.Theme) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.theme = theme;
    }
    fn onWebTitleChanged(ctx: *anyopaque, id: u32, title: []const u8) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        if (st.on_title_changed) |f| f(st.handle, title, st.on_title_changed_ctx);
    }
    fn onWebUrlChanged(ctx: *anyopaque, id: u32, url: []const u8) void {
        _ = ctx;
        _ = id;
        _ = url;
    }
    fn onWebLoadStarted(ctx: *anyopaque, id: u32) void {
        const self = fromCtx(ctx);
        if (self.windowState(.{ .id = id })) |st| st.dom_ready = false;
    }
    fn onWebLoadFinished(ctx: *anyopaque, id: u32) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        if (st.on_load_finished) |f| f(st.handle, st.on_load_finished_ctx);
    }
    fn onWebLoadFailed(ctx: *anyopaque, id: u32, reason: []const u8) void {
        _ = ctx;
        log.err("page load failed in window {d}: {s}", .{ id, reason });
    }
    fn onWebDomReady(ctx: *anyopaque, id: u32) void {
        const self = fromCtx(ctx);
        if (self.windowState(.{ .id = id })) |st| st.dom_ready = true;
    }
    fn onWebMessage(ctx: *anyopaque, id: u32, message: []const u8) void {
        const self = fromCtx(ctx);
        if (self.windowState(.{ .id = id }) == null) return;
        self.ipc.deliver(id, message);
    }
    fn onWebConsole(ctx: *anyopaque, id: u32, level: events.ConsoleLevel, text: []const u8) void {
        _ = ctx;
        _ = level;
        log.debug("console[{d}]: {s}", .{ id, text });
    }
    fn onWebNavigationRequested(ctx: *anyopaque, id: u32, url: []const u8) bool {
        _ = ctx;
        _ = id;
        _ = url;
        return true;
    }
    fn onSurfaceResized(ctx: *anyopaque, id: u32, width: i32, height: i32, scale: f32) void {
        const self = fromCtx(ctx);
        const st = self.windowState(.{ .id = id }) orelse return;
        st.width = width;
        st.height = height;
        st.scale = scale;
    }
    fn onSurfaceInput(ctx: *anyopaque, id: u32, input: events.Input) void {
        const self = fromCtx(ctx);
        // A native window's input goes to the application's own handler. The
        // backend reports DIPs, so a handler compares against layout rectangles
        // directly.
        if (self.surface_input) |handler| {
            if (input == .pointer_down) _ = handler.call(handler.ctx, id, input.pointer_down.x, input.pointer_down.y);
        }
    }
    fn onSurfaceFrameRequested(ctx: *anyopaque, id: u32) void {
        _ = ctx;
        _ = id;
    }
    fn onMenuCommand(ctx: *anyopaque, id: []const u8) void {
        const self = fromCtx(ctx);
        // A menu click is an application event: listeners on the Zig side and
        // subscribers on the page both see it, with the same name the bridge
        // documents.
        _ = self.emit("menu:command", .{ .string = id });
    }

    fn onNotificationClicked(ctx: *anyopaque, tag: []const u8) void {
        _ = ctx;
        _ = tag;
    }
    fn onTrayClicked(ctx: *anyopaque, item: u32) void {
        _ = ctx;
        _ = item;
    }
    fn onShortcutPressed(ctx: *anyopaque, accel: []const u8) void {
        _ = ctx;
        _ = accel;
    }
    fn onThemeChanged(ctx: *anyopaque, theme: events.Theme) void {
        fromCtx(ctx).theme = theme;
    }
    fn onDispatch(ctx: *anyopaque) void {
        _ = fromCtx(ctx).queue.drain();
    }

    /// Looks up a file in the application's embedded frontend by its path
    /// relative to the bundle root. Returns null when the app has no frontend
    /// or the path is unknown.
    pub fn frontendFile(self: *const App, path: []const u8) ?FrontendFile {
        for (self.options.frontend) |f| {
            if (std.mem.eql(u8, f.path, path)) return f;
        }
        return null;
    }

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

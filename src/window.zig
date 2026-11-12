//! The window: a native top-level window showing a web page, native UI, or
//! both.
//!
//! A `Window` value is a **handle**, not the window itself. It is eight bytes
//! (`id` plus a generation counter) and can be copied freely. The window's
//! state lives in the `App`'s registry, owned by the application. A handle
//! whose window has been destroyed reports `isValid() == false` and every
//! operation on it returns `error.InvalidWindow` rather than touching freed
//! memory.
//!
//! Ownership:
//!
//! * The `App` owns every window. `createWindow` returns a handle; the window
//!   lives until it is closed, by the user, by `close`, or by `App.deinit`.
//! * Strings in `WindowOptions` are copied into the window's arena at creation
//!   time, so a caller may pass stack memory or a temporary buffer.
//! * Callbacks registered on a window are called on the main thread and must
//!   not allocate beyond the reply context they are given.

const std = @import("std");
const backend = @import("platform/backend.zig");
const events = @import("events.zig");
const errors = @import("errors.zig");
const log = @import("log.zig");

pub const Rect = backend.Rect;
pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { width: i32, height: i32 };

/// What a window shows.
pub const Content = union(enum) {
    /// A web page in the system webview.
    web: []const u8,
    /// Native UI drawn by MyZig on the GPU. The function is called on the main
    /// thread once per frame with the window's UI context.
    native: *const fn (ctx: *anyopaque) void,
};

/// Options for `App.createWindow`. Every field has a default; the zero value
/// gives an 800x600 centered, resizable, visible window titled after the app.
pub const WindowOptions = struct {
    /// Window title. Defaults to the application name.
    title: []const u8 = "",
    /// The page to load, for a window showing a web page. URLs without a
    /// scheme (`"/"`, `"index.html"`) are served by the app's frontend
    /// protocol; `http://` and `https://` URLs load from the network in
    /// development and are blocked in production unless allowed.
    url: []const u8 = "",
    /// A view function for a window showing native UI. Setting `viewport`
    /// picks native UI; setting `url` picks a page.
    view: ?*const fn (ctx: *anyopaque) void = null,
    /// Opaque pointer passed to `view`, typically the app's state.
    view_context: ?*anyopaque = null,
    /// Whether the window shows both: a native surface behind, a web view in
    /// front. Set with `view` and `url` both present.
    hybrid: bool = false,

    width: i32 = 800,
    height: i32 = 600,
    /// Position; `null` centers the window on the focused display.
    x: ?i32 = null,
    y: ?i32 = null,

    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,

    /// Creates the window without showing it.
    hidden: bool = false,
    /// No title bar and no borders; the content draws them.
    frameless: bool = false,
    /// Hides the title bar but keeps the window buttons over the content.
    hidden_titlebar: bool = false,
    resizable: bool = true,
    movable: bool = true,
    minimizable: bool = true,
    maximizable: bool = true,
    closable: bool = true,
    fullscreenable: bool = true,
    always_on_top: bool = false,
    skip_taskbar: bool = false,
    transparent: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    /// A parent window, for dialogs and child windows.
    parent: ?Window = null,
    modal: bool = false,
    /// Background colour while a page loads, as 0xRRGGBBAA.
    background: u32 = 0xffffffff,

    /// Remember the window's position, size and state under this key in the
    /// app's data directory.
    state_key: []const u8 = "",
};

/// A handle to a window. Copyable; safe to store.
pub const Window = struct {
    id: u32 = 0,
    generation: u16 = 0,

    pub const invalid: Window = .{};

    pub fn isValid(self: Window, app: *const @import("app.zig").App) bool {
        return app.windowValid(self);
    }

    pub fn eql(a: Window, b: Window) bool {
        return a.id == b.id and a.generation == b.generation;
    }

    /// The window's current id, for logs.
    pub fn rawId(self: Window) u32 {
        return self.id;
    }
};

/// The state MyZig keeps for one open window.
pub const WindowState = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    handle: Window,
    /// Strings below live in the arena.
    title: []const u8 = "",
    url: []const u8 = "",
    state_key: []const u8 = "",
    view: ?*const fn (ctx: *anyopaque) void = null,
    view_context: ?*anyopaque = null,
    kind: backend.ContentKind = .web,

    width: i32 = 800,
    height: i32 = 600,
    x: i32 = 0,
    y: i32 = 0,
    scale: f32 = 1.0,

    visible: bool = true,
    focused: bool = false,
    state: events.WindowState = .normal,
    theme: events.Theme = .light,
    dom_ready: bool = false,

    resizable: bool = true,
    closable: bool = true,

    /// Per-window secret mixed into page -> Zig messages.
    secret: u64 = 0,

    on_close: ?*const fn (w: Window, ctx: ?*anyopaque) void = null,
    on_close_ctx: ?*anyopaque = null,
    on_focus: ?*const fn (w: Window, focused: bool, ctx: ?*anyopaque) void = null,
    on_focus_ctx: ?*anyopaque = null,
    on_resize: ?*const fn (w: Window, size: Size, ctx: ?*anyopaque) void = null,
    on_resize_ctx: ?*anyopaque = null,
    on_load_finished: ?*const fn (w: Window, ctx: ?*anyopaque) void = null,
    on_load_finished_ctx: ?*anyopaque = null,
    on_title_changed: ?*const fn (w: Window, title: []const u8, ctx: ?*anyopaque) void = null,
    on_title_changed_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, handle: Window) WindowState {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .handle = handle,
        };
    }

    pub fn deinit(self: *WindowState) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Duplicates a string into this window's arena.
    pub fn intern(self: *WindowState, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    /// The window arena's allocator, for values that live as long as the
    /// window.
    pub fn arenaAllocator(self: *WindowState) std.mem.Allocator {
        return self.arena.allocator();
    }
};

test "window handles compare by id and generation" {
    const a = Window{ .id = 1, .generation = 0 };
    const b = Window{ .id = 1, .generation = 1 };
    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!Window.invalid.eql(a));
}

test "window state interns into its arena" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var st = WindowState.init(gpa, .{ .id = 1 });
    defer st.deinit();
    const s = try st.intern("hello");
    try std.testing.expectEqualStrings("hello", s);
    const t = try st.intern("world");
    try std.testing.expectEqualStrings("world", t);
    // Freed in one call by deinit; DebugAllocator checks for leaks.
}

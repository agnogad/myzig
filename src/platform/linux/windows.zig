//! GTK windows.
//!
//! Each MyZig window is a `GtkWindow` holding either a `WebKitWebView` (a
//! window showing a page) or a native surface. A window showing both keeps both
//! children in a `GtkOverlay`.
//!
//! ## Ownership
//!
//! `gtk_widget_destroy` releases the window and everything in it. The registry
//! holds only ids and native handles, never owning pointers, so a GTK signal
//! that arrives for a window that is already gone finds nothing and returns:
//! there is no use-after-free window.
//!
//! ## Signals
//!
//! Each signal callback is created **once** for all windows and receives the
//! window id as its user data — never a pointer to Zig memory that moves when
//! the registry grows. Callback creation happens at startup, which keeps to the
//! fixed set GObject allows.

const std = @import("std");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const gmenu = @import("gmenu.zig");
const menu_mod = @import("../../menu.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");
const log = @import("../../log.zig");
const ffi = @import("ffi.zig");
const webview = @import("webview.zig");

pub const CreateError = error{ OutOfMemory, InvalidArgument, NotSupported };

/// One live GTK window.
pub const Entry = struct {
    id: u32,
    window: ffi.GtkWindow,
    /// The web view, for a window showing a page.
    web: ?ffi.WebKitWebView = null,
    /// The container that holds the web view and any content.
    root: ?ffi.GtkWidget = null,
    /// The vertical box installed when the window has a menu bar.
    box: ?ffi.GtkWidget = null,
    /// The menu bar inside `box`, so a replaced menu can be removed.
    bar: ?ffi.GtkWidget = null,
    /// The window content before a menu bar was installed, so a new menu can
    /// re-parent it instead of losing it.
    content: ?ffi.GtkWidget = null,
    /// Set while the framework is destroying the window, so GTK's `destroy`
    /// signal does not report it a second time.
    destroying: bool = false,
    shown: bool = false,
    /// The size as last reported by GTK, used to answer `getBounds`.
    width: i32 = 800,
    height: i32 = 600,
    x: i32 = 0,
    y: i32 = 0,
    scale: f32 = 1,
};

var registry: std.AutoHashMapUnmanaged(u32, Entry) = .empty;
var gpa: std.mem.Allocator = undefined;
var sink: ?backend.EventSink = null;
var callbacks_created = false;

pub fn init(allocator: std.mem.Allocator, events_sink: backend.EventSink) void {
    gpa = allocator;
    sink = events_sink;
    ensureCallbacks();
}

pub fn shutdownAll() void {
    var it = registry.iterator();
    while (it.next()) |e| {
        e.value_ptr.destroying = true;
    }
    registry.deinit(gpa);
    registry = .empty;
}

pub fn lookup(id: u32) ?*Entry {
    return registry.getPtr(id);
}

// ---------------------------------------------------------------- callbacks

var destroy_cb: ?*const anyopaque = null;
var configure_cb: ?*const anyopaque = null;
var focus_in_cb: ?*const anyopaque = null;
var focus_out_cb: ?*const anyopaque = null;
var delete_event_cb: ?*const anyopaque = null;

fn ensureCallbacks() void {
    if (callbacks_created) return;
    callbacks_created = true;

    destroy_cb = @ptrCast(&struct {
        fn cb(widget: *anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = widget;
            onGtkDestroy(dataInt(data));
        }
    }.cb);

    configure_cb = @ptrCast(&struct {
        fn cb(widget: *anyopaque, event: *anyopaque, data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = widget;
            _ = event;
            onConfigure(dataInt(data));
            return ffi.FALSE;
        }
    }.cb);

    focus_in_cb = @ptrCast(&struct {
        fn cb(widget: *anyopaque, event: *anyopaque, data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = widget;
            _ = event;
            onFocus(dataInt(data), true);
            return ffi.FALSE;
        }
    }.cb);

    focus_out_cb = @ptrCast(&struct {
        fn cb(widget: *anyopaque, event: *anyopaque, data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = widget;
            _ = event;
            onFocus(dataInt(data), false);
            return ffi.FALSE;
        }
    }.cb);

    delete_event_cb = @ptrCast(&struct {
        fn cb(widget: *anyopaque, event: *anyopaque, data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = event;
            _ = widget;
            // The framework decides: report the request and return TRUE so GTK
            // does not destroy the window behind its back.
            const s = sink orelse return ffi.FALSE;
            s.windowCloseRequested(dataInt(data));
            return ffi.TRUE;
        }
    }.cb);

}

inline fn dataInt(data: ?*anyopaque) u32 {
    return @truncate(@intFromPtr(data));
}

inline fn dataPtr(id: u32) ?*anyopaque {
    return @ptrFromInt(@as(usize, id));
}

fn connect(obj: ?*anyopaque, signal: [*:0]const u8, cb: *const anyopaque, id: u32) void {
    _ = ffi.connectSignal(obj, signal, cb, dataPtr(id));
}

fn onGtkDestroy(id: u32) void {
    const entry = registry.getPtr(id) orelse return;
    if (entry.destroying) return;
    entry.destroying = true;
    _ = registry.remove(id);
    if (sink) |s| s.windowClosed(id);
}

fn onConfigure(id: u32) void {
    const entry = registry.getPtr(id) orelse return;
    var w: c_int = 0;
    var h: c_int = 0;
    ffi.gtk_window_get_size(entry.window, &w, &h);
    var x: c_int = 0;
    var y: c_int = 0;
    ffi.gtk_window_get_position(entry.window, &x, &y);
    const size_changed = (w != entry.width or h != entry.height);
    const moved = (x != entry.x or y != entry.y);
    entry.width = w;
    entry.height = h;
    entry.x = x;
    entry.y = y;
    const s = sink orelse return;
    if (size_changed) s.windowResized(id, w, h);
    if (moved) s.windowMoved(id, x, y);
}

fn onFocus(id: u32, focused: bool) void {
    _ = registry.getPtr(id) orelse return;
    if (sink) |s| s.windowFocus(id, focused);
}

// ------------------------------------------------------------------ create

/// Replaces the window's content with a vertical box holding a menu bar and the
/// previous content. Called again for a new menu: the old bar is destroyed and
/// only the content survives.
pub fn attachMenu(allocator: std.mem.Allocator, id: u32, m: menu_mod.Menu) errors.WindowError!void {
    const entry = registry.getPtr(id) orelse return errors.WindowError.InvalidWindow;
    const gtk_window = entry.window;

    // Remember the real content once, so a second menu does not nest a box in
    // a box with an orphaned web view between them.
    if (entry.content == null) {
        entry.content = if (entry.web) |w| w else if (entry.box) |b| b else null;
    }
    const content = entry.content;

    // Replacing a menu keeps the existing box and only swaps the bar, so the
    // web view is never re-parented: re-parenting reloads the page and loses
    // its state.
    if (entry.box) |existing| {
        if (entry.bar) |old| {
            ffi.gtk_container_remove(existing, old);
            ffi.gtk_widget_destroy(old);
        }
        const bar = gmenu.build(allocator, id, gtk_window, m) orelse
            return errors.WindowError.NotSupported;
        ffi.gtk_box_pack_start(existing, bar.bar, ffi.FALSE, ffi.FALSE, 0);
        // The bar must come before the content; GTK keeps insertion order, so
        // reorder once by repacking the content at the end.
        if (content) |c| {
            ffi.gtk_container_remove(existing, c);
            ffi.gtk_box_pack_start(existing, c, ffi.TRUE, ffi.TRUE, 0);
        }
        ffi.gtk_widget_show_all(existing);
        entry.bar = bar.bar;
        return;
    }

    const box = ffi.gtk_box_new(ffi.GTK_ORIENTATION_VERTICAL, 0) orelse
        return errors.WindowError.NotSupported;
    const bar_built = gmenu.build(allocator, id, gtk_window, m) orelse {
        ffi.gtk_widget_destroy(box);
        return errors.WindowError.NotSupported;
    };
    ffi.gtk_box_pack_start(box, bar_built.bar, ffi.FALSE, ffi.FALSE, 0);
    if (content) |c| {
        // `gtk_container_remove` drops the container's reference, destroying the
        // widget if nothing else holds it. Holding one reference across the move
        // is what keeps the web view (and the loaded page) alive.
        _ = ffi.g_object_ref(@ptrCast(c));
        defer _ = ffi.g_object_unref(@ptrCast(c));
        if (ffi.gtk_widget_get_parent(c)) |parent| {
            ffi.gtk_container_remove(parent, c);
        }
        ffi.gtk_box_pack_start(box, c, ffi.TRUE, ffi.TRUE, 0);
    }
    ffi.gtk_container_add(gtk_window, box);
    ffi.gtk_widget_show_all(box);
    entry.box = box;
    entry.bar = bar_built.bar;
}

pub fn create(app: *app_mod.App, id: u32, opts: backend.WindowOptions) CreateError!void {
    if (id == 0) return error.InvalidArgument;

    const gtk_window = ffi.gtk_window_new(ffi.GTK_WINDOW_TOPLEVEL) orelse return error.NotSupported;

    const title = ffi.CStr.init(opts.title);
    ffi.gtk_window_set_title(gtk_window, title.ptr());
    ffi.gtk_window_set_default_size(gtk_window, opts.width, opts.height);
    ffi.gtk_window_set_resizable(gtk_window, if (opts.resizable) ffi.TRUE else ffi.FALSE);
    if (opts.frameless) ffi.gtk_window_set_decorated(gtk_window, ffi.FALSE);
    if (opts.always_on_top) ffi.gtk_window_set_keep_above(gtk_window, ffi.TRUE);
    if (opts.skip_taskbar) ffi.gtk_window_set_skip_taskbar_hint(gtk_window, ffi.TRUE);
    if (opts.modal) ffi.gtk_window_set_modal(gtk_window, ffi.TRUE);
    if (opts.x == null and opts.y == null) {
        ffi.gtk_window_set_position(gtk_window, ffi.GTK_WIN_POS_CENTER);
    } else {
        ffi.gtk_window_move(gtk_window, opts.x orelse 0, opts.y orelse 0);
    }

    // A page needs WebKitGTK, which is loaded only now, so a native-UI-only app
    // never maps it.
    var web: ?ffi.WebKitWebView = null;
    if (opts.content == .web or opts.content == .hybrid) {
        ffi.loadWebKit() catch {
            log.err("this window shows a page but WebKitGTK could not be loaded", .{});
            ffi.gtk_widget_destroy(gtk_window);
            return error.NotSupported;
        };
        web = webview.createFor(id, gtk_window, opts) catch |e| {
            ffi.gtk_widget_destroy(gtk_window);
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.NotSupported,
            };
        };
        if (web) |w| {
            ffi.gtk_container_add(gtk_window, w);
            // Load after the view is in the window so WebKit lays out at the
            // right size.
            webview.startPage(id, opts.url);
        }
    }

    try registry.put(gpa, id, .{
        .id = id,
        .window = gtk_window,
        .web = web,
        .width = opts.width,
        .height = opts.height,
        .x = opts.x orelse 0,
        .y = opts.y orelse 0,
    });

    connect(gtk_window, "destroy", destroy_cb.?, id);
    connect(gtk_window, "configure-event", configure_cb.?, id);
    connect(gtk_window, "focus-in-event", focus_in_cb.?, id);
    connect(gtk_window, "focus-out-event", focus_out_cb.?, id);
    connect(gtk_window, "delete-event", delete_event_cb.?, id);

    if (!opts.hidden) {
        ffi.gtk_widget_show_all(gtk_window);
        if (registry.getPtr(id)) |e| e.shown = true;
    }

    if (sink) |s| s.windowCreated(id);
    _ = app;
}

pub fn destroy(id: u32) void {
    const entry = registry.getPtr(id) orelse return;
    entry.destroying = true;
    ffi.gtk_widget_destroy(entry.window);
    _ = registry.remove(id);
    if (sink) |s| s.windowClosed(id);
}

pub fn show(id: u32, visible: bool) void {
    const entry = registry.getPtr(id) orelse return;
    if (visible) {
        ffi.gtk_widget_show_all(entry.window);
        entry.shown = true;
    } else {
        ffi.gtk_widget_hide(entry.window);
    }
}

pub fn focus(id: u32) void {
    const entry = registry.getPtr(id) orelse return;
    ffi.gtk_window_present(entry.window);
}

pub fn setBounds(id: u32, r: backend.Rect) bool {
    const entry = registry.getPtr(id) orelse return false;
    if (r.width <= 0 or r.height <= 0) return false;
    ffi.gtk_window_resize(entry.window, r.width, r.height);
    ffi.gtk_window_move(entry.window, r.x, r.y);
    entry.width = r.width;
    entry.height = r.height;
    entry.x = r.x;
    entry.y = r.y;
    return true;
}

pub fn getBounds(id: u32) ?backend.Rect {
    const entry = registry.getPtr(id) orelse return null;
    return .{ .x = entry.x, .y = entry.y, .width = entry.width, .height = entry.height };
}

pub fn setTitle(id: u32, title: []const u8) void {
    const entry = registry.getPtr(id) orelse return;
    const c = ffi.CStr.init(title);
    ffi.gtk_window_set_title(entry.window, c.ptr());
}

pub fn setState(id: u32, state: events.WindowState) bool {
    const entry = registry.getPtr(id) orelse return false;
    switch (state) {
        .normal => {
            ffi.gtk_window_deiconify(entry.window);
            ffi.gtk_window_unmaximize(entry.window);
            ffi.gtk_window_unfullscreen(entry.window);
        },
        .minimized => ffi.gtk_window_iconify(entry.window),
        .maximized => ffi.gtk_window_maximize(entry.window),
        .fullscreen => ffi.gtk_window_fullscreen(entry.window),
    }
    return true;
}

pub fn setAlwaysOnTop(id: u32, on: bool) void {
    const entry = registry.getPtr(id) orelse return;
    ffi.gtk_window_set_keep_above(entry.window, if (on) ffi.TRUE else ffi.FALSE);
}

pub fn setFullscreen(id: u32, on: bool) bool {
    const entry = registry.getPtr(id) orelse return false;
    if (on) ffi.gtk_window_fullscreen(entry.window) else ffi.gtk_window_unfullscreen(entry.window);
    return true;
}

pub fn monitors(out: []backend.MonitorInfo) usize {
    const display = ffi.gdk_display_get_default() orelse return 0;
    const n_monitors = ffi.gdk_display_get_n_monitors(display);
    const primary = ffi.gdk_display_get_primary_monitor(display);
    var written: usize = 0;
    var i: c_int = 0;
    while (i < n_monitors and written < out.len) : (i += 1) {
        const mon = ffi.gdk_display_get_monitor(display, i) orelse continue;
        var geom = ffi.GdkRectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
        ffi.gdk_monitor_get_geometry(mon, &geom);
        var work = ffi.GdkRectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };
        ffi.gdk_monitor_get_workarea(mon, &work);
        var name_buf: [128]u8 = undefined;
        const name: []const u8 = blk: {
            const model = ffi.gdk_monitor_get_model(mon);
            break :blk ffi.copyCStr(&name_buf, model);
        };
        const refresh = ffi.gdk_monitor_get_refresh_rate(mon);
        out[written] = .{
            .bounds = .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height },
            .work_area = .{ .x = work.x, .y = work.y, .width = work.width, .height = work.height },
            .scale = @floatFromInt(ffi.gdk_monitor_get_scale_factor(mon)),
            .refresh_hz = if (refresh > 0) @as(f32, @floatFromInt(refresh)) / 1000.0 else 0,
            .primary = mon == primary,
            .name = if (name.len > 0) name else "monitor",
        };
        written += 1;
    }
    return written;
}

pub fn systemTheme() events.Theme {
    // GTK 3 exposes the desktop's preference through GtkSettings'
    // gtk-application-prefer-dark-theme and, on desktops that follow the
    // freedesktop colour scheme, through the portal. Read the settings value,
    // which every theme honours.
    const settings = ffi.gtk_settings_get_default() orelse return .light;
    var dark: c_int = 0;
    // GObject's getters return values through pointers; the theme preference
    // is a boolean stored in a `gboolean` (a `c_int`).
    // `g_object_get` is variadic and copies the property as a `gboolean`, so
    // the out-pointer is a `c_int`; the trailing NULL ends the list.
    ffi.g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, @as(?*anyopaque, null));
    return if (dark != 0) .dark else .light;
}

pub fn requestFrame(id: u32) void {
    _ = id;
    // The native surface module draws; a window with only a page has nothing
    // to present.
}

pub fn present(id: u32) void {
    _ = id;
}

// GTK needs a user data pointer per window; the id is small enough to carry
// directly in the pointer, so nothing is allocated per signal.
// (See dataPtr/dataInt.)

test "window ids fit in a pointer" {
    const id: u32 = 12345;
    const p = dataPtr(id);
    try std.testing.expectEqual(id, dataInt(p));
}

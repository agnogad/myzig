//! Tray icons and global shortcuts.
//!
//! ## Tray
//!
//! GTK 3's `GtkStatusIcon` is deprecated but works on every desktop that still
//! shows a status area, and needs no extra library. Vanishingly few X11
//! sessions have no tray at all; when there is none, `gtk_status_icon_is_embedded`
//! says so and the caller gets a clear answer instead of an invisible icon.
//!
//! ## Shortcuts
//!
//! A *global* shortcut (one that fires while another application has focus) is
//! a platform service: on X11 it needs a grabbed key, which fails whenever
//! another client already holds the same combination. This module reports that
//! failure rather than pretending the shortcut exists.

const std = @import("std");
const ffi = @import("ffi.zig");
const log = @import("../../log.zig");
const menu_mod = @import("../../menu.zig");

/// A tray icon the application owns.
pub const Tray = struct {
    icon: ffi.GtkStatusIcon,
    /// The tooltip, owned by this module.
    tooltip: [:0]u8,
};

var tray: ?Tray = null;
var tray_allocator: std.mem.Allocator = std.heap.page_allocator;

/// The click callback, installed by the backend so a click reaches the app.
pub const ClickSink = struct {
    report: *const fn (ctx: *anyopaque, tag: []const u8) void,
    ctx: *anyopaque,
};

var click_sink: ?ClickSink = null;

pub fn setClickSink(sink: ClickSink) void {
    click_sink = sink;
}

/// Shows a tray icon from a themed icon name such as `"applications-system"`.
/// Returns false when the desktop has no tray, or the theme has no such icon.
pub fn create(allocator: std.mem.Allocator, icon_name: []const u8, tooltip: []const u8) bool {
    destroy();
    tray_allocator = allocator;

    const name = ffi.CStr.init(icon_name);
    const icon = ffi.gtk_status_icon_new_from_icon_name(name.ptr()) orelse {
        log.err("tray: the theme has no icon named '{s}'", .{icon_name});
        return false;
    };

    // A NUL-terminated copy, owned here: GTK keeps the pointer for the life of
    // the icon. Zig 0.17 removed `Allocator.dupeZ`, so the terminator is added
    // by hand.
    const owned = allocator.alloc(u8, tooltip.len + 1) catch {
        _ = ffi.g_object_unref(@ptrCast(icon));
        return false;
    };
    @memcpy(owned[0..tooltip.len], tooltip);
    owned[tooltip.len] = 0;
    const tip = owned[0..tooltip.len :0];
    ffi.gtk_status_icon_set_tooltip_text(icon, tip.ptr);
    ffi.gtk_status_icon_set_visible(icon, ffi.TRUE);

    _ = ffi.g_signal_connect_data(icon, "activate", @ptrCast(&onActivate), null, null, 0);

    tray = .{ .icon = icon, .tooltip = tip };

    // An icon that is not embedded has no status area to live in, which is a
    // real limitation the application should hear about.
    if (ffi.gtk_status_icon_is_embedded(icon) == ffi.FALSE) {
        log.debug("tray: the desktop shows no status area; the icon is hidden", .{});
        return false;
    }
    return true;
}

fn onActivate(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const sink = click_sink orelse return;
    sink.report(sink.ctx, "tray");
}

pub fn destroy() void {
    if (tray) |t| {
        _ = ffi.g_object_unref(@ptrCast(t.icon));
        tray_allocator.free(t.tooltip);
        tray = null;
    }
}

// ------------------------------------------------------------- shortcuts

/// One global accelerator the application asked for.
pub const Shortcut = struct {
    accel: menu_mod.Accelerator,
    /// The text the application used, returned in the callback.
    text: []const u8,
};

/// X11 is loaded at runtime, like GTK and WebKit: MyZig links no libraries, so
/// an application that never binds a global shortcut does not map libX11.
const X11 = struct {
    lib: std.DynLib,

    xgrabkey: *const fn (*anyopaque, c_int, c_uint, c_ulong, c_int, c_int, c_int) callconv(.c) c_int,
    xungrabkey: *const fn (*anyopaque, c_int, c_uint, c_ulong) callconv(.c) c_int,
    xkeysym_to_keycode: *const fn (*anyopaque, c_ulong) callconv(.c) u8,
    xdefault_root_window: *const fn (*anyopaque) callconv(.c) c_ulong,
    xsync: *const fn (*anyopaque, c_int) callconv(.c) c_int,
    xset_error_handler: *const fn (?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int) callconv(.c) ?*const anyopaque,
};

var x11: ?X11 = null;
var x11_tried = false;

fn loadX11() ?*X11 {
    if (x11) |*x| return x;
    if (x11_tried) return null;
    x11_tried = true;

    var lib = std.DynLib.open("libX11.so.6") catch return null;
    const xgrabkey = lib.lookup(*const fn (*anyopaque, c_int, c_uint, c_ulong, c_int, c_int, c_int) callconv(.c) c_int, "XGrabKey") orelse return null;
    const xungrabkey = lib.lookup(*const fn (*anyopaque, c_int, c_uint, c_ulong) callconv(.c) c_int, "XUngrabKey") orelse return null;
    const xkeysym_to_keycode = lib.lookup(*const fn (*anyopaque, c_ulong) callconv(.c) u8, "XKeysymToKeycode") orelse return null;
    const xdefault_root_window = lib.lookup(*const fn (*anyopaque) callconv(.c) c_ulong, "XDefaultRootWindow") orelse return null;
    const xsync = lib.lookup(*const fn (*anyopaque, c_int) callconv(.c) c_int, "XSync") orelse return null;
    const xset_error_handler = lib.lookup(*const fn (?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int) callconv(.c) ?*const anyopaque, "XSetErrorHandler") orelse return null;

    x11 = .{
        .lib = lib,
        .xgrabkey = xgrabkey,
        .xungrabkey = xungrabkey,
        .xkeysym_to_keycode = xkeysym_to_keycode,
        .xdefault_root_window = xdefault_root_window,
        .xsync = xsync,
        .xset_error_handler = xset_error_handler,
    };
    return &x11.?;
}

/// The X display GDK already opened, so a grab uses the same connection. GDK is
/// loaded by the backend, so this symbol is present whenever a window exists.
var gdk_lib: ?std.DynLib = null;
var gdk_get_xdisplay: ?*const fn () callconv(.c) ?*anyopaque = null;

fn loadGdk() ?*const fn () callconv(.c) ?*anyopaque {
    if (gdk_get_xdisplay) |f| return f;
    if (gdk_lib == null) {
        gdk_lib = std.DynLib.open("libgdk-3.so.0") catch return null;
    }
    const f = gdk_lib.?.lookup(*const fn () callconv(.c) ?*anyopaque, "gdk_x11_get_default_xdisplay") orelse return null;
    gdk_get_xdisplay = f;
    return f;
}

/// Grabs use `GrabModeAsync` on both the pointer and the keyboard, which means
/// X does not freeze input while the grab is active.
const GrabModeAsync: c_int = 1;

/// X11 reports a failed grab asynchronously through the error handler. The
/// handler records the last error so `registerShortcut` can report it: without
/// this, a shortcut already taken by another client would look bound.
var last_x_error: c_int = 0;

fn onXError(_: ?*anyopaque, event: ?*anyopaque) callconv(.c) c_int {
    if (event) |e| {
        // An XErrorEvent's first field is its type, then the display, then the
        // resource id, then the serial, the error code and the request code.
        const bytes: [*]const u8 = @ptrCast(e);
        const code = bytes[16..20];
        last_x_error = std.mem.readInt(c_int, code[0..4], .native);
    }
    return 0;
}

/// Grabbed shortcuts, so they can be released again.
var shortcuts: std.ArrayListUnmanaged(Shortcut) = .empty;

/// Binds a global accelerator: it fires while any application has focus.
///
/// Returns `error.NotSupported` on a session that is not X11 (Wayland forbids
/// global grabs by design or through a portal), and `error.AlreadyTaken` when
/// another client holds the same combination.
pub fn registerShortcut(allocator: std.mem.Allocator, sc: Shortcut) error{ NotSupported, AlreadyTaken, OutOfMemory }!void {
    const get_display = loadGdk() orelse return error.NotSupported;
    const lib = loadX11() orelse return error.NotSupported;
    const display = get_display() orelse return error.NotSupported;
    const root = lib.xdefault_root_window(display);

    const keycode = lib.xkeysym_to_keycode(display, keyvalOf(sc.accel.key));
    if (keycode == 0) return error.NotSupported;

    const mods = xModsOf(sc.accel);

    // Every lock state must be grabbed, or the shortcut stops working while
    // CapsLock or NumLock happens to be on. The same applies to each lock
    // combination, so four grabs cover the sets people actually use.
    const masks = [_]c_uint{
        mods,
        mods | 2, // LockMask
        mods | 16, // Mod2Mask (NumLock on most layouts)
        mods | 2 | 16,
    };
    last_x_error = 0;
    for (masks) |m| {
        _ = lib.xgrabkey(display, keycode, m, root, 0, GrabModeAsync, GrabModeAsync);
    }
    _ = lib.xsync(display, 0);
    if (last_x_error != 0) {
        // Nothing is half-bound: release the grabs that did succeed.
        for (masks) |m| _ = lib.xungrabkey(display, keycode, m, root);
        _ = lib.xsync(display, 0);
        last_x_error = 0;
        return error.AlreadyTaken;
    }

    try shortcuts.append(allocator, sc);
}

pub fn unregisterAll(allocator: std.mem.Allocator) void {
    const get_display = loadGdk() orelse return;
    const lib = loadX11() orelse return;
    const display = get_display() orelse return;
    const root = lib.xdefault_root_window(display);
    for (shortcuts.items) |sc| {
        const keycode = lib.xkeysym_to_keycode(display, keyvalOf(sc.accel.key));
        if (keycode == 0) continue;
        const mods = xModsOf(sc.accel);
        _ = X11.XUngrabKey(display, keycode, mods, root);
        _ = X11.XUngrabKey(display, keycode, mods | 2, root);
        _ = X11.XUngrabKey(display, keycode, mods | 16, root);
        _ = X11.XUngrabKey(display, keycode, mods | 2 | 16, root);
    }
    _ = X11.XSync(display, 0);
    shortcuts.deinit(allocator);
    shortcuts = .empty;
}

/// X11 modifier bits: shift 1, control 4, alt (Mod1) 8, super (Mod4) 64.
fn xModsOf(a: menu_mod.Accelerator) c_uint {
    var m: c_uint = 0;
    if (a.shift) m |= 1;
    if (a.ctrl) m |= 4;
    if (a.alt) m |= 8;
    if (a.meta) m |= 64;
    return m;
}

fn keyvalOf(key: menu_mod.Accelerator.Key) c_ulong {
    // X11 keysyms: Latin-1 letters and digits are their code points, and the
    // named keys use the X11R6 keysym range.
    const K = menu_mod.Accelerator.Key;
    return switch (key) {
        .unknown => 0,
        .space => 0x020,
        .tab => 0xff09,
        .enter => 0xff0d,
        .escape => 0xff1b,
        .backspace => 0xff08,
        .delete => 0xffff,
        .insert => 0xff63,
        .home => 0xff50,
        .end => 0xff57,
        .page_up => 0xff55,
        .page_down => 0xff56,
        .arrow_up => 0xff52,
        .arrow_down => 0xff54,
        .arrow_left => 0xff51,
        .arrow_right => 0xff53,
        .f1 => 0xffbe,
        .f2 => 0xffbf,
        .f3 => 0xffc0,
        .f4 => 0xffc1,
        .f5 => 0xffc2,
        .f6 => 0xffc3,
        .f7 => 0xffc4,
        .f8 => 0xffc5,
        .f9 => 0xffc6,
        .f10 => 0xffc7,
        .f11 => 0xffc8,
        .f12 => 0xffc9,
        .comma => ',',
        .period => '.',
        .slash => '/',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .bracket_left => '[',
        .bracket_right => ']',
        .minus => '-',
        .equals => '=',
        .grave => '`',
        else => |k| blk: {
            const n = @backingInt(k);
            const a = @backingInt(K.a);
            const d = @backingInt(K.digit_0);
            if (n >= a and n < a + 26) break :blk @as(c_ulong, 'a') + (n - a);
            if (n >= d and n < d + 10) break :blk @as(c_ulong, '0') + (n - d);
            break :blk 0;
        },
    };
}

/// Installs the X error handler the grab needs. Called once, from the backend.
pub fn installErrorHandler() void {
    const lib = loadX11() orelse return;
    _ = lib.xset_error_handler(onXError);
}

test "the module compiles and exposes its API" {
    // The GTK calls need a display, so the behaviour is verified by the
    // `tray` example; this asserts the contract is present.
    try std.testing.expect(@intFromPtr(&create) != 0);
    try std.testing.expect(@intFromPtr(&destroy) != 0);
}

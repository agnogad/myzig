//! GTK 3, GLib, GObject, GDK and WebKitGTK 4.1 bindings, resolved at run time.
//!
//! Every symbol is looked up lazily. `load()` opens the libraries and resolves
//! the core set; `loadWebKit()` resolves the web engine's symbols only when the
//! first window showing a page is created, so a native-UI-only application never
//! maps WebKit.
//!
//! Types are the C ones: `?*anyopaque` for GObject pointers, `c_int` for
//! booleans (`gboolean`), and function pointers declared with the exact C
//! prototype so that calls need no casting at the call site.

const std = @import("std");
const errors = @import("../../errors.zig");
const log = @import("../../log.zig");
const env = @import("../../utils/env.zig");

// ---------------------------------------------------------------- C types

pub const GBytes = *anyopaque;
pub const gboolean = c_int;
pub const guint = c_uint;
/// `G_PRIORITY_DEFAULT_IDLE`: run when nothing more urgent is pending.
pub const G_PRIORITY_DEFAULT_IDLE: c_int = 200;
pub const GDK_CURRENT_TIME: u32 = 0;
pub const GTK_FILE_CHOOSER_ACTION_OPEN: c_int = 0;
pub const GTK_FILE_CHOOSER_ACTION_SAVE: c_int = 1;
pub const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: c_int = 2;
pub const GTK_RESPONSE_ACCEPT: c_int = -3;
pub const GTK_RESPONSE_CANCEL: c_int = -6;
pub const GTK_RESPONSE_OK: c_int = -5;
pub const GTK_BUTTONS_NONE: c_int = 4;
pub const GTK_MESSAGE_INFO: c_int = 0;
pub const GTK_MESSAGE_WARNING: c_int = 1;
pub const GTK_MESSAGE_QUESTION: c_int = 2;
pub const GTK_MESSAGE_ERROR: c_int = 3;
pub const GTK_DIALOG_MODAL: c_int = 1;
pub const G_SPAWN_SEARCH_PATH: c_int = 1;
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
pub const GTK_ACCEL_VISIBLE: c_int = 1;
pub const gint = c_int;
pub const gulong = c_ulong;
pub const gpointer = *anyopaque;
pub const GError = opaque {};

/// A `GError` as the C ABI lays it out, for the rare call that needs to build
/// one. MyZig only ever *creates* an error to fail a scheme request, so the
/// fields it does not set stay null.
pub const GErrorFull = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]u8,
};
pub const GCancellable = opaque {};
pub const GMainLoop = ?*anyopaque;
pub const GMainContext = ?*anyopaque;
pub const GtkWidget = *anyopaque;
pub const GtkWindow = *anyopaque;
pub const GtkClipboard = *anyopaque;
pub const GtkFileFilter = *anyopaque;
pub const GtkFileChooserDialog = *anyopaque;
pub const GtkDialog = *anyopaque;
pub const GtkBox = *anyopaque;
pub const GtkStatusIcon = *anyopaque;
pub const GSimpleAction = *anyopaque;
pub const GtkContainer = *anyopaque;
pub const GdkWindow = *anyopaque;
pub const GdkDisplay = *anyopaque;
pub const GdkMonitor = *anyopaque;
pub const GdkScreen = *anyopaque;
pub const GdkPixbuf = *anyopaque;
pub const WebKitWebView = *anyopaque;
pub const WebKitWebInspector = *anyopaque;
pub const WebKitUserScript = *anyopaque;
pub const WebKitUserContentManager = *anyopaque;
pub const WebKitUserContentInjectedFrames = c_int;
pub const WebKitUserScriptInjectionTime = c_int;
pub const GtkWidgetPath = *anyopaque;

pub const TRUE: gboolean = 1;
pub const FALSE: gboolean = 0;

pub const GdkRectangle = extern struct {
    x: gint,
    y: gint,
    width: gint,
    height: gint,
};

pub const GdkRGBA = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// The portable ABI for `std.DynLib`. `c` on Unix, `kernel32` on Windows.
const abi = if (@import("builtin").os.tag == .windows) std.DynLib else std.c;

// ------------------------------------------------------------- libraries

var lib_glib: ?std.DynLib = null;
var lib_gobject: ?std.DynLib = null;
var lib_gtk: ?std.DynLib = null;
var lib_cairo: ?std.DynLib = null;
var lib_gio: ?std.DynLib = null;
var lib_gdk: ?std.DynLib = null;
var lib_webkit: ?std.DynLib = null;
var webkit_version: enum { none, v4_0, v4_1 } = .none;
var loaded = false;
var webkit_loaded = false;

/// Names tried in order: WebKitGTK 4.1 first, 4.0 as a fallback for older
/// distributions.
const webkit_names = [_][]const u8{ "libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.1.so" };
const webkit_names_40 = [_][]const u8{ "libwebkit2gtk-4.0.so.37", "libwebkit2gtk-4.0.so" };

fn openLib(names: []const []const u8) ?std.DynLib {
    for (names) |name| {
        if (std.DynLib.open(name)) |lib| return lib else |_| continue;
    }
    return null;
}

fn resolve(lib: *std.DynLib, comptime T: type, comptime name: [:0]const u8) ?T {
    return lib.lookup(T, name);
}

fn mustResolve(lib: *std.DynLib, comptime T: type, comptime name: [:0]const u8) errors.InitError!T {
    return lib.lookup(T, name) orelse {
        log.err("symbol missing: {s}", .{name});
        return errors.InitError.SymbolMissing;
    };
}

// --------------------------------------------------------------- symbol table
pub const GSFunc = ?*const fn (?gpointer) callconv(.c) gboolean;

// GLib
pub var g_set_prgname: *const fn (name: [*:0]const u8) callconv(.c) void = undefined;
pub var g_idle_add_full: *const fn (priority: c_int, func: GSFunc, data: ?gpointer, notify: ?*const fn (?gpointer) callconv(.c) void) callconv(.c) guint = undefined;
pub var g_main_context_iteration: *const fn (ctx: GMainContext, may_block: gboolean) callconv(.c) gboolean = undefined;
pub var g_main_context_wakeup: *const fn (ctx: GMainContext) callconv(.c) void = undefined;
pub var g_main_loop_new: *const fn (ctx: GMainContext, is_running: gboolean) callconv(.c) GMainLoop = undefined;
pub var g_main_loop_run: *const fn (loop: GMainLoop) callconv(.c) void = undefined;
pub var g_main_loop_quit: *const fn (loop: GMainLoop) callconv(.c) void = undefined;
pub var g_main_loop_unref: *const fn (loop: GMainLoop) callconv(.c) void = undefined;
pub var g_error_free: *const fn (err: *GError) callconv(.c) void = undefined;
pub var g_free: *const fn (p: ?gpointer) callconv(.c) void = undefined;
pub var g_memory_input_stream_new_from_bytes: *const fn (bytes: ?gpointer) callconv(.c) ?gpointer = undefined;
pub var g_bytes_new_static: *const fn (data: ?*const anyopaque, size: usize) callconv(.c) ?gpointer = undefined;
pub var g_bytes_unref: *const fn (b: ?gpointer) callconv(.c) void = undefined;
pub var g_quark_from_static_string: *const fn (s: [*:0]const u8) callconv(.c) u32 = undefined;
pub var g_strfreev: *const fn (v: ?[*]?[*:0]u8) callconv(.c) void = undefined;
pub var g_timeout_add: *const fn (ms: guint, func: GSFunc, data: ?gpointer) callconv(.c) guint = undefined;
pub var g_source_remove: *const fn (id: guint) callconv(.c) gboolean = undefined;
pub var g_get_monotonic_time: *const fn () callconv(.c) i64 = undefined;
pub var g_get_prgname: *const fn () callconv(.c) ?[*:0]const u8 = undefined;
pub var g_unix_signal_add: *const fn (signum: c_int, func: GSFunc, data: ?gpointer) callconv(.c) guint = undefined;

// GObject
pub var g_signal_connect_data: *const fn (obj: ?gpointer, signal: [*:0]const u8, cb: ?*const anyopaque, data: ?gpointer, destroy: ?*const anyopaque, flags: c_int) callconv(.c) gulong = undefined;
pub var g_signal_handler_disconnect: *const fn (obj: gpointer, id: gulong) callconv(.c) void = undefined;
pub var g_object_ref: *const fn (obj: gpointer) callconv(.c) gpointer = undefined;
pub var g_object_ref_sink: *const fn (obj: gpointer) callconv(.c) gpointer = undefined;
pub var g_object_unref: *const fn (obj: gpointer) callconv(.c) void = undefined;
/// `g_object_get(obj, first_property, ..., NULL)`: variadic, terminated by
/// NULL. Callers pass property names and out-pointers matching the property's
/// type, exactly as in C.
pub var g_object_get: *const fn (obj: gpointer, first: [*:0]const u8, ...) callconv(.c) void = undefined;
/// `g_object_set(obj, first_property, ..., NULL)`: variadic, terminated by
/// NULL.
pub var g_object_set: *const fn (obj: gpointer, first: [*:0]const u8, ...) callconv(.c) void = undefined;

// GTK
pub var gtk_init_check: *const fn (argc: *c_int, argv: *[*c][*c]u8) callconv(.c) gboolean = undefined;
pub var gtk_window_new: *const fn (type: c_int) callconv(.c) ?GtkWindow = undefined;
pub var gtk_window_set_title: *const fn (w: GtkWindow, title: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_window_get_title: *const fn (w: GtkWindow) callconv(.c) ?[*:0]const u8 = undefined;
pub var gtk_window_set_default_size: *const fn (w: GtkWindow, width: gint, height: gint) callconv(.c) void = undefined;
pub var gtk_window_set_resizable: *const fn (w: GtkWindow, v: gboolean) callconv(.c) void = undefined;
pub var gtk_window_set_decorated: *const fn (w: GtkWindow, v: gboolean) callconv(.c) void = undefined;
pub var gtk_window_set_keep_above: *const fn (w: GtkWindow, v: gboolean) callconv(.c) void = undefined;
pub var gtk_window_set_skip_taskbar_hint: *const fn (w: GtkWindow, v: gboolean) callconv(.c) void = undefined;
pub var gtk_window_set_modal: *const fn (w: GtkWindow, v: gboolean) callconv(.c) void = undefined;
pub var gtk_window_set_transient_for: *const fn (w: GtkWindow, parent: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_set_position: *const fn (w: GtkWindow, pos: c_int) callconv(.c) void = undefined;
pub var gtk_window_move: *const fn (w: GtkWindow, x: gint, y: gint) callconv(.c) void = undefined;
pub var gtk_window_resize: *const fn (w: GtkWindow, width: gint, height: gint) callconv(.c) void = undefined;
pub var gtk_window_get_size: *const fn (w: GtkWindow, width: *gint, height: *gint) callconv(.c) void = undefined;
pub var gtk_window_get_position: *const fn (w: GtkWindow, x: *gint, y: *gint) callconv(.c) void = undefined;
pub var gtk_window_iconify: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_deiconify: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_maximize: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_unmaximize: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_fullscreen: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_unfullscreen: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_window_set_geometry_hints: *const fn (w: GtkWindow, geom: ?*anyopaque, hints: ?*anyopaque, mask: c_int) callconv(.c) void = undefined;
pub var gtk_clipboard_get: *const fn (selection: gpointer) callconv(.c) ?GtkClipboard = undefined;
pub var gtk_clipboard_wait_for_text: *const fn (cb: GtkClipboard) callconv(.c) ?[*:0]u8 = undefined;
pub var gtk_clipboard_set_text: *const fn (cb: GtkClipboard, text: [*:0]const u8, len: gint) callconv(.c) void = undefined;
pub var gtk_clipboard_store: *const fn (cb: GtkClipboard) callconv(.c) gboolean = undefined;
pub var gtk_file_chooser_dialog_new: *const fn (
    title: [*:0]const u8,
    parent: ?GtkWindow,
    action: c_int,
    first_button: [*:0]const u8,
    ...,
) callconv(.c) ?GtkFileChooserDialog = undefined;
pub var gtk_file_chooser_set_select_multiple: *const fn (d: GtkFileChooserDialog, v: gboolean) callconv(.c) void = undefined;
pub var gtk_file_chooser_set_current_name: *const fn (d: GtkFileChooserDialog, name: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_file_chooser_get_filename: *const fn (d: GtkFileChooserDialog) callconv(.c) ?[*:0]u8 = undefined;
pub var gtk_file_chooser_get_filenames: *const fn (d: GtkFileChooserDialog) callconv(.c) ?[*:null]?[*:0]u8 = undefined;
pub var gtk_file_chooser_add_filter: *const fn (d: GtkFileChooserDialog, f: ?GtkFileFilter) callconv(.c) void = undefined;
pub var gtk_file_filter_new: *const fn () callconv(.c) ?GtkFileFilter = undefined;
pub var gtk_file_filter_set_name: *const fn (f: GtkFileFilter, name: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_file_filter_add_pattern: *const fn (f: GtkFileFilter, pattern: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_dialog_run: *const fn (d: GtkDialog) callconv(.c) gint = undefined;
pub var gtk_dialog_add_button: *const fn (d: GtkDialog, label: [*:0]const u8, id: gint) callconv(.c) ?*anyopaque = undefined;
pub var gtk_message_dialog_new: *const fn (
    parent: ?GtkWindow,
    flags: c_int,
    kind: c_int,
    buttons: c_int,
    first: [*:0]const u8,
    ...,
) callconv(.c) ?GtkDialog = undefined;
pub var gtk_show_uri_on_window: *const fn (
    parent: ?GtkWindow,
    uri: [*:0]const u8,
    timestamp: u32,
    err: ?*GErrorFull,
) callconv(.c) gboolean = undefined;
pub var g_spawn_async: *const fn (
    dir: ?[*:0]const u8,
    argv: [*]const [*:0]const u8,
    envp: ?[*]const [*:0]const u8,
    flags: c_int,
    child_setup: ?*const anyopaque,
    user_data: ?gpointer,
    child_pid: ?*c_int,
) callconv(.c) gboolean = undefined;

pub var gtk_status_icon_new_from_icon_name: *const fn (name: [*:0]const u8) callconv(.c) ?GtkStatusIcon = undefined;
pub var gtk_status_icon_set_tooltip_text: *const fn (icon: GtkStatusIcon, text: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_status_icon_set_visible: *const fn (icon: GtkStatusIcon, visible: gboolean) callconv(.c) void = undefined;
pub var gtk_status_icon_is_embedded: *const fn (icon: GtkStatusIcon) callconv(.c) gboolean = undefined;

pub var gtk_menu_bar_new: *const fn () callconv(.c) ?GtkWidget = undefined;
pub var gtk_menu_new: *const fn () callconv(.c) ?GtkWidget = undefined;
pub var gtk_menu_item_new_with_label: *const fn (label: [*:0]const u8) callconv(.c) ?GtkWidget = undefined;
pub var gtk_menu_item_new_with_mnemonic: *const fn (label: [*:0]const u8) callconv(.c) ?GtkWidget = undefined;
pub var gtk_menu_item_set_submenu: *const fn (item: GtkWidget, submenu: ?GtkWidget) callconv(.c) void = undefined;
pub var gtk_menu_item_set_label: *const fn (item: GtkWidget, label: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_menu_shell_append: *const fn (shell: GtkWidget, child: GtkWidget) callconv(.c) void = undefined;
pub var gtk_separator_menu_item_new: *const fn () callconv(.c) ?GtkWidget = undefined;
pub var gtk_check_menu_item_new_with_label: *const fn (label: [*:0]const u8) callconv(.c) ?GtkWidget = undefined;
pub var gtk_check_menu_item_set_active: *const fn (item: GtkWidget, active: gboolean) callconv(.c) void = undefined;
pub var gtk_check_menu_item_get_active: *const fn (item: GtkWidget) callconv(.c) gboolean = undefined;
pub var gtk_box_pack_start: *const fn (b: GtkBox, child: GtkWidget, expand: gboolean, fill: gboolean, padding: u32) callconv(.c) void = undefined;
pub var gtk_widget_set_sensitive: *const fn (w: GtkWidget, sensitive: gboolean) callconv(.c) void = undefined;
pub var gtk_accel_group_new: *const fn () callconv(.c) ?gpointer = undefined;
pub var gtk_window_add_accel_group: *const fn (w: GtkWindow, group: gpointer) callconv(.c) void = undefined;
pub var gtk_widget_add_accelerator: *const fn (
    w: GtkWidget,
    accel_signal: [*:0]const u8,
    group: gpointer,
    accel_key: c_uint,
    accel_mods: c_int,
    flags: c_int,
) callconv(.c) void = undefined;

pub var gtk_window_set_default_icon_name: *const fn (name: [*:0]const u8) callconv(.c) void = undefined;
pub var gtk_window_set_type_hint: *const fn (w: GtkWindow, hint: c_int) callconv(.c) void = undefined;
pub var gtk_window_present: *const fn (w: GtkWindow) callconv(.c) void = undefined;
pub var gtk_widget_show: *const fn (w: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_show_all: *const fn (w: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_hide: *const fn (w: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_destroy: *const fn (w: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_grab_focus: *const fn (w: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_queue_draw: *const fn (w: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_set_can_focus: *const fn (w: GtkWidget, v: gboolean) callconv(.c) void = undefined;
pub var gtk_widget_add_events: *const fn (w: GtkWidget, ev: gint) callconv(.c) void = undefined;
pub var gtk_box_new: *const fn (orientation: c_int, spacing: gint) callconv(.c) ?GtkBox = undefined;

// ------------------------------------------------------- native drawing area
// A native window paints into a `GtkDrawingArea`: GDK hands the draw signal a
// cairo context, and the toolkit's software rasteriser blits its buffer into
// it. That is the one piece of GTK the native renderer needs.
pub const GtkDrawingArea = *anyopaque;
pub const GtkAllocation = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
pub const DrawSignal = *const fn (widget: GtkWidget, cr: gpointer, user_data: ?*anyopaque) callconv(.c) gboolean;
pub const SizeSignal = *const fn (widget: GtkWidget, alloc: *GtkAllocation, user_data: ?*anyopaque) callconv(.c) void;

pub var gtk_drawing_area_new: *const fn () callconv(.c) ?GtkDrawingArea = undefined;
pub var gtk_event_box_new: *const fn () callconv(.c) ?GtkWidget = undefined;
pub var gtk_widget_set_double_buffered: *const fn (w: GtkWidget, v: gboolean) callconv(.c) void = undefined;
pub var gtk_widget_set_size_request: *const fn (w: GtkWidget, width: gint, height: gint) callconv(.c) void = undefined;
pub var gtk_widget_get_pointer: *const fn (w: GtkWidget, x: ?*f64, y: ?*f64) callconv(.c) void = undefined;
pub var gtk_widget_get_window: *const fn (w: GtkWidget) callconv(.c) ?gpointer = undefined;

// cairo: only what is needed to push an RGBA32 buffer to the drawing area.
pub const CairoImageSurface = *anyopaque;
pub var cairo_image_surface_create_for_data: *const fn (data: [*]u8, format: c_int, width: c_int, height: c_int, stride: c_int) callconv(.c) ?CairoImageSurface = undefined;
pub var cairo_create: *const fn (target: CairoImageSurface) callconv(.c) ?gpointer = undefined;
pub var cairo_set_source_surface: *const fn (cr: gpointer, surface: CairoImageSurface, x: f64, y: f64) callconv(.c) void = undefined;
pub var cairo_paint: *const fn (cr: gpointer) callconv(.c) void = undefined;
pub var cairo_destroy: *const fn (cr: gpointer) callconv(.c) void = undefined;
pub var cairo_surface_destroy: *const fn (surface: CairoImageSurface) callconv(.c) void = undefined;
pub var cairo_surface_flush: *const fn (surface: CairoImageSurface) callconv(.c) void = undefined;
pub var cairo_scale: *const fn (cr: gpointer, sx: f64, sy: f64) callconv(.c) void = undefined;
pub var gtk_container_add: *const fn (c: GtkContainer, child: GtkWidget) callconv(.c) void = undefined;
pub var gtk_widget_get_parent: *const fn (w: GtkWidget) callconv(.c) ?GtkWidget = undefined;
pub var gtk_container_remove: *const fn (c: GtkContainer, child: GtkWidget) callconv(.c) void = undefined;
pub var gtk_window_set_default_icon_from_file: *const fn (f: [*:0]const u8, err: *?*GError) callconv(.c) gboolean = undefined;
pub var gtk_settings_get_default: *const fn () callconv(.c) ?gpointer = undefined;
pub var gtk_style_context_new: *const fn () callconv(.c) gpointer = undefined;
pub var gtk_main: *const fn () callconv(.c) void = undefined;
pub var gtk_main_quit: *const fn () callconv(.c) void = undefined;
pub var gtk_main_iteration_do: *const fn (blocking: gboolean) callconv(.c) gboolean = undefined;
pub var gtk_events_pending: *const fn () callconv(.c) gboolean = undefined;

// GDK
pub var gdk_atom_intern: *const fn (name: [*:0]const u8, only_if_exists: gboolean) callconv(.c) gpointer = undefined;
pub var gdk_display_get_default: *const fn () callconv(.c) ?GdkDisplay = undefined;
pub var gdk_display_get_name: *const fn (d: GdkDisplay) callconv(.c) [*:0]const u8 = undefined;
pub var gdk_display_get_default_screen: *const fn (d: GdkDisplay) callconv(.c) GdkScreen = undefined;
pub var gdk_display_get_n_monitors: *const fn (d: GdkDisplay) callconv(.c) gint = undefined;
pub var gdk_display_get_monitor: *const fn (d: GdkDisplay, i: gint) callconv(.c) ?GdkMonitor = undefined;
pub var gdk_display_get_primary_monitor: *const fn (d: GdkDisplay) callconv(.c) ?GdkMonitor = undefined;
pub var gdk_monitor_get_geometry: *const fn (m: GdkMonitor, g: *GdkRectangle) callconv(.c) void = undefined;
pub var gdk_monitor_get_workarea: *const fn (m: GdkMonitor, a: *GdkRectangle) callconv(.c) void = undefined;
pub var gdk_monitor_get_scale_factor: *const fn (m: GdkMonitor) callconv(.c) gint = undefined;
pub var gdk_monitor_get_refresh_rate: *const fn (m: GdkMonitor) callconv(.c) gint = undefined;
pub var gdk_monitor_get_model: *const fn (m: GdkMonitor) callconv(.c) ?[*:0]u8 = undefined;
pub var gdk_screen_get_default: *const fn () callconv(.c) GdkScreen = undefined;
pub var gdk_screen_get_resolution: *const fn (s: GdkScreen) callconv(.c) f64 = undefined;
pub var gdk_screen_is_composited: *const fn (s: GdkScreen) callconv(.c) gboolean = undefined;
pub var gdk_screen_get_rgba_visual: *const fn (s: GdkScreen) callconv(.c) gpointer = undefined;
pub var gdk_window_get_frame_extents: *const fn (w: GdkWindow, r: *GdkRectangle) callconv(.c) void = undefined;
pub var gdk_window_get_type: *const fn () callconv(.c) usize = undefined;
pub var gdk_window_set_transient_for: *const fn (w: GdkWindow, parent: GdkWindow) callconv(.c) void = undefined;
pub var gdk_cairo_set_source_rgba: *const fn (cr: gpointer, rgba: *const GdkRGBA) callconv(.c) void = undefined;
pub var gdk_wayland_display_get_type: *const fn () callconv(.c) usize = undefined;
pub var gdk_x11_display_get_type: *const fn () callconv(.c) usize = undefined;

// WebKitGTK
pub var webkit_web_view_new_with_user_content_manager: *const fn (ucm: WebKitUserContentManager) callconv(.c) ?WebKitWebView = undefined;
pub var webkit_user_content_manager_new: *const fn () callconv(.c) ?WebKitUserContentManager = undefined;
pub var webkit_user_content_manager_register_script_message_handler: *const fn (ucm: WebKitUserContentManager, name: [*:0]const u8) callconv(.c) gboolean = undefined;
pub var webkit_user_content_manager_add_script: *const fn (ucm: WebKitUserContentManager, script: WebKitUserScript) callconv(.c) void = undefined;
pub var webkit_user_script_unref: *const fn (sc: WebKitUserScript) callconv(.c) void = undefined;
pub var webkit_user_script_new: *const fn (source: [*:0]const u8, frames: WebKitUserContentInjectedFrames, time: WebKitUserScriptInjectionTime, allow_list: ?*anyopaque, block_list: ?*anyopaque) callconv(.c) ?WebKitUserScript = undefined;
pub var webkit_web_view_load_uri: *const fn (w: WebKitWebView, uri: [*:0]const u8) callconv(.c) void = undefined;
pub var webkit_web_view_load_html: *const fn (w: WebKitWebView, content: [*:0]const u8, base_uri: ?[*:0]const u8) callconv(.c) void = undefined;
pub var webkit_web_view_run_javascript: *const fn (w: WebKitWebView, script: [*:0]const u8, cancel: ?*GCancellable, cb: ?*const anyopaque, data: ?gpointer) callconv(.c) void = undefined;
pub var webkit_web_view_call_async_javascript_function: *const fn (w: WebKitWebView, body: [*:0]const u8, len: c_long, args: ?*anyopaque, world: ?[*:0]const u8, source_uri: ?[*:0]const u8, cancel: ?*GCancellable, cb: ?*const anyopaque, data: ?gpointer) callconv(.c) void = undefined;
pub var webkit_web_view_get_title: *const fn (w: WebKitWebView) callconv(.c) ?[*:0]u8 = undefined;
pub var webkit_web_view_get_uri: *const fn (w: WebKitWebView) callconv(.c) ?[*:0]u8 = undefined;
pub var webkit_web_view_reload: *const fn (w: WebKitWebView) callconv(.c) void = undefined;
pub var webkit_web_view_go_back: *const fn (w: WebKitWebView) callconv(.c) void = undefined;
pub var webkit_web_view_go_forward: *const fn (w: WebKitWebView) callconv(.c) void = undefined;
pub var webkit_web_view_can_go_back: *const fn (w: WebKitWebView) callconv(.c) gboolean = undefined;
pub var webkit_web_view_can_go_forward: *const fn (w: WebKitWebView) callconv(.c) gboolean = undefined;
pub var webkit_web_view_set_background_color: *const fn (w: WebKitWebView, color: *const GdkRGBA) callconv(.c) void = undefined;
pub var webkit_web_view_set_zoom_level: *const fn (w: WebKitWebView, z: f64) callconv(.c) void = undefined;
pub var webkit_web_view_get_zoom_level: *const fn (w: WebKitWebView) callconv(.c) f64 = undefined;
pub var webkit_web_view_get_settings: *const fn (w: WebKitWebView) callconv(.c) ?gpointer = undefined;
pub var webkit_web_view_get_user_content_manager: *const fn (w: WebKitWebView) callconv(.c) WebKitUserContentManager = undefined;
pub var webkit_settings_set_enable_developer_extras: *const fn (s: gpointer, v: gboolean) callconv(.c) void = undefined;
pub var webkit_settings_set_enable_javascript: *const fn (s: gpointer, v: gboolean) callconv(.c) void = undefined;
pub var webkit_settings_set_enable_write_console_messages_to_stdout: *const fn (s: gpointer, v: gboolean) callconv(.c) void = undefined;
pub var webkit_settings_set_enable_smooth_scrolling: *const fn (s: gpointer, v: gboolean) callconv(.c) void = undefined;
pub var webkit_settings_set_hardware_acceleration_policy: *const fn (s: gpointer, p: c_int) callconv(.c) void = undefined;
pub var webkit_settings_set_user_agent: *const fn (s: gpointer, ua: ?[*:0]const u8) callconv(.c) void = undefined;
pub var webkit_security_manager_register_uri_scheme_as_cors_enabled: *const fn (sm: gpointer, scheme: [*:0]const u8) callconv(.c) void = undefined;
pub var webkit_security_manager_register_uri_scheme_as_secure: *const fn (sm: gpointer, scheme: [*:0]const u8) callconv(.c) void = undefined;
pub var webkit_uri_scheme_request_get_uri: *const fn (r: gpointer) callconv(.c) ?[*:0]const u8 = undefined;
pub var webkit_uri_scheme_request_get_path: *const fn (r: gpointer) callconv(.c) ?[*:0]const u8 = undefined;
pub var webkit_uri_scheme_request_get_http_method: *const fn (r: gpointer) callconv(.c) ?[*:0]const u8 = undefined;
pub var webkit_uri_scheme_request_finish: *const fn (r: gpointer, stream: gpointer, len: i64, mime: [*:0]const u8) callconv(.c) void = undefined;
pub var webkit_uri_scheme_request_finish_error: *const fn (r: gpointer, err: *GErrorFull) callconv(.c) void = undefined;
pub var webkit_web_context_get_security_manager: *const fn (ctx: gpointer) callconv(.c) ?gpointer = undefined;
pub var webkit_web_context_register_uri_scheme: *const fn (ctx: gpointer, scheme: [*:0]const u8, cb: ?*const anyopaque, data: ?gpointer, destroy: ?*const anyopaque) callconv(.c) void = undefined;
pub var webkit_web_context_get_default: *const fn () callconv(.c) ?gpointer = undefined;
pub var webkit_web_context_set_cache_model: *const fn (ctx: gpointer, model: c_int) callconv(.c) void = undefined;
pub var webkit_web_context_clear_cache: *const fn (ctx: gpointer) callconv(.c) void = undefined;
pub var webkit_web_view_terminate_web_process: *const fn (w: WebKitWebView) callconv(.c) void = undefined;
pub var webkit_web_view_get_estimated_load_progress: *const fn (w: WebKitWebView) callconv(.c) f64 = undefined;
pub var webkit_web_inspector_show: *const fn (i: WebKitWebInspector) callconv(.c) void = undefined;
pub var webkit_web_view_get_inspector: *const fn (w: WebKitWebView) callconv(.c) ?WebKitWebInspector = undefined;
pub var webkit_javascript_result_get_js_value: *const fn (r: gpointer) callconv(.c) ?gpointer = undefined;
pub var webkit_javascript_result_unref: *const fn (r: gpointer) callconv(.c) void = undefined;
pub var webkit_navigation_action_get_request: *const fn (a: gpointer) callconv(.c) ?gpointer = undefined;
pub var webkit_policy_decision_ignore: *const fn (d: gpointer) callconv(.c) void = undefined;
pub var webkit_navigation_policy_decision_get_navigation_action: *const fn (d: gpointer) callconv(.c) ?gpointer = undefined;
pub var webkit_uri_request_get_uri: *const fn (r: gpointer) callconv(.c) ?[*:0]const u8 = undefined;
pub var webkit_navigation_action_is_user_gesture: *const fn (a: gpointer) callconv(.c) gboolean = undefined;
pub var webkit_web_view_load_bytes: *const fn (w: WebKitWebView, bytes: GBytes, mime: ?[*:0]const u8, enc: ?[*:0]const u8, base: ?[*:0]const u8) callconv(.c) void = undefined;

// ------------------------------------------------------------------ loading

/// Opens GLib, GObject, GDK and GTK and resolves their symbols. Idempotent.
pub fn load() errors.InitError!void {
    if (loaded) return;

    var glib = openLib(&.{"libglib-2.0.so.0"}) orelse return errors.InitError.LibraryMissing;
    errdefer glib.close();
    var gobject = openLib(&.{"libgobject-2.0.so.0"}) orelse return errors.InitError.LibraryMissing;
    errdefer gobject.close();
    var gdk = openLib(&.{"libgdk-3.so.0"}) orelse return errors.InitError.LibraryMissing;
    errdefer gdk.close();
    var gtk = openLib(&.{"libgtk-3.so.0"}) orelse return errors.InitError.LibraryMissing;
    errdefer gtk.close();
    var gio = openLib(&.{"libgio-2.0.so.0"}) orelse return errors.InitError.LibraryMissing;
    errdefer gio.close();

    try bindAll(&glib, glib_syms);
    try bindAll(&gobject, gobject_syms);
    try bindAll(&gdk, gdk_syms);
    try bindAll(&gtk, gtk_syms);
    try bindAll(&gio, gio_syms);

    lib_glib = glib;
    lib_gobject = gobject;
    lib_gdk = gdk;
    lib_gtk = gtk;
    lib_gio = gio;
    loaded = true;
}

/// Resolves cairo. Only a native window that paints itself needs it, so a
/// page-only application never maps the library.
var cairo_loaded = false;
pub fn loadCairo() errors.InitError!void {
    if (cairo_loaded) return;
    var lib = openLib(&.{"libcairo.so.2"}) orelse {
        log.err("cairo is not installed; the native renderer needs libcairo2", .{});
        return errors.InitError.LibraryMissing;
    };
    errdefer lib.close();
    try bindAll(&lib, cairo_syms);
    lib_cairo = lib;
    cairo_loaded = true;
}

/// Resolves WebKitGTK. Called when the first page-showing window is created.
pub fn loadWebKit() errors.InitError!void {
    if (webkit_loaded) return;
    var lib = openLib(&webkit_names);
    if (lib != null) {
        webkit_version = .v4_1;
    } else {
        lib = openLib(&webkit_names_40);
        if (lib != null) webkit_version = .v4_0;
    }
    var real = lib orelse {
        log.err(
            "WebKitGTK is not installed; install webkit2gtk-4.1 " ++
                "(Arch: webkit2gtk-4.1, Debian: libwebkit2gtk-4.1-0)",
            .{},
        );
        return errors.InitError.LibraryMissing;
    };
    errdefer real.close();
    try bindAll(&real, webkit_syms);
    lib_webkit = real;
    webkit_loaded = true;
}

pub fn unload() void {
    if (lib_cairo) |*l| l.close();
    if (lib_webkit) |*l| l.close();
    if (lib_gtk) |*l| l.close();
    if (lib_gdk) |*l| l.close();
    if (lib_gobject) |*l| l.close();
    if (lib_glib) |*l| l.close();
    lib_webkit = null;
    lib_gtk = null;
    lib_gdk = null;
    lib_gobject = null;
    lib_glib = null;
    loaded = false;
    webkit_loaded = false;
    webkit_version = .none;
}

pub fn isLoaded() bool {
    return loaded;
}

pub fn hasWebKit() bool {
    return webkit_loaded;
}

pub fn webkitVersionName() []const u8 {
    return switch (webkit_version) {
        .none => "none",
        .v4_0 => "4.0",
        .v4_1 => "4.1",
    };
}

/// Resolves every symbol in `syms` into the module-level variable of the same
/// name. `syms` is a comptime tuple of `.{ zig_name, c_name }` pairs; the Zig
/// name must be a declaration here, which is checked at compile time, so a
/// renamed C function cannot silently bind to the wrong pointer type.
fn bindAll(lib: *std.DynLib, comptime syms: anytype) errors.InitError!void {
    inline for (syms) |pair| {
        const value = lib.lookup(@TypeOf(@field(@This(), pair[0])), pair[1]) orelse {
            log.err("symbol missing: {s}", .{pair[1]});
            return errors.InitError.SymbolMissing;
        };
        @field(@This(), pair[0]) = value;
    }
}

const glib_syms = .{
    .{ "g_set_prgname", "g_set_prgname" },
    .{ "g_idle_add_full", "g_idle_add_full" },
    .{ "g_main_context_iteration", "g_main_context_iteration" },
    .{ "g_main_context_wakeup", "g_main_context_wakeup" },
    .{ "g_main_loop_new", "g_main_loop_new" },
    .{ "g_main_loop_run", "g_main_loop_run" },
    .{ "g_main_loop_quit", "g_main_loop_quit" },
    .{ "g_main_loop_unref", "g_main_loop_unref" },
    .{ "g_error_free", "g_error_free" },
    .{ "g_free", "g_free" },
    .{ "g_spawn_async", "g_spawn_async" },
    .{ "g_bytes_new_static", "g_bytes_new_static" },
    .{ "g_bytes_unref", "g_bytes_unref" },
    .{ "g_quark_from_static_string", "g_quark_from_static_string" },
    .{ "g_strfreev", "g_strfreev" },
    .{ "g_timeout_add", "g_timeout_add" },
    .{ "g_source_remove", "g_source_remove" },
    .{ "g_get_monotonic_time", "g_get_monotonic_time" },
    .{ "g_unix_signal_add", "g_unix_signal_add" },
    .{ "g_get_prgname", "g_get_prgname" },
};

const gobject_syms = .{
    .{ "g_signal_connect_data", "g_signal_connect_data" },
    .{ "g_signal_handler_disconnect", "g_signal_handler_disconnect" },
    .{ "g_object_ref", "g_object_ref" },
    .{ "g_object_ref_sink", "g_object_ref_sink" },
    .{ "g_object_unref", "g_object_unref" },
    .{ "g_object_get", "g_object_get" },
    .{ "g_object_set", "g_object_set" },
};

/// `libgio-2.0` provides the stream types. Kept apart from GLib so a missing
/// GIO is reported as such.
const cairo_syms = .{
    .{ "cairo_image_surface_create_for_data", "cairo_image_surface_create_for_data" },
    .{ "cairo_create", "cairo_create" },
    .{ "cairo_set_source_surface", "cairo_set_source_surface" },
    .{ "cairo_paint", "cairo_paint" },
    .{ "cairo_destroy", "cairo_destroy" },
    .{ "cairo_surface_destroy", "cairo_surface_destroy" },
    .{ "cairo_surface_flush", "cairo_surface_flush" },
    .{ "cairo_scale", "cairo_scale" },
};

const gio_syms = .{
    .{ "g_memory_input_stream_new_from_bytes", "g_memory_input_stream_new_from_bytes" },
};

const gdk_syms = .{
    .{ "gdk_display_get_default", "gdk_display_get_default" },
    .{ "gdk_display_get_name", "gdk_display_get_name" },
    .{ "gdk_display_get_default_screen", "gdk_display_get_default_screen" },
    .{ "gdk_display_get_n_monitors", "gdk_display_get_n_monitors" },
    .{ "gdk_display_get_monitor", "gdk_display_get_monitor" },
    .{ "gdk_display_get_primary_monitor", "gdk_display_get_primary_monitor" },
    .{ "gdk_monitor_get_geometry", "gdk_monitor_get_geometry" },
    .{ "gdk_monitor_get_workarea", "gdk_monitor_get_workarea" },
    .{ "gdk_monitor_get_scale_factor", "gdk_monitor_get_scale_factor" },
    .{ "gdk_monitor_get_refresh_rate", "gdk_monitor_get_refresh_rate" },
    .{ "gdk_monitor_get_model", "gdk_monitor_get_model" },
    .{ "gdk_screen_get_default", "gdk_screen_get_default" },
    .{ "gdk_screen_is_composited", "gdk_screen_is_composited" },
    .{ "gdk_window_get_frame_extents", "gdk_window_get_frame_extents" },
    .{ "gdk_atom_intern", "gdk_atom_intern" },
    .{ "gdk_cairo_set_source_rgba", "gdk_cairo_set_source_rgba" },
    .{ "gdk_screen_get_resolution", "gdk_screen_get_resolution" },
    .{ "gdk_screen_get_rgba_visual", "gdk_screen_get_rgba_visual" },
    .{ "gdk_wayland_display_get_type", "gdk_wayland_display_get_type" },
    .{ "gdk_window_get_type", "gdk_window_get_type" },
    .{ "gdk_window_set_transient_for", "gdk_window_set_transient_for" },
    .{ "gdk_x11_display_get_type", "gdk_x11_display_get_type" },
};

const gtk_syms = .{
    .{ "gtk_init_check", "gtk_init_check" },
    .{ "gtk_window_new", "gtk_window_new" },
    .{ "gtk_window_set_title", "gtk_window_set_title" },
    .{ "gtk_window_get_title", "gtk_window_get_title" },
    .{ "gtk_window_set_default_size", "gtk_window_set_default_size" },
    .{ "gtk_window_set_resizable", "gtk_window_set_resizable" },
    .{ "gtk_window_set_decorated", "gtk_window_set_decorated" },
    .{ "gtk_window_set_keep_above", "gtk_window_set_keep_above" },
    .{ "gtk_window_set_skip_taskbar_hint", "gtk_window_set_skip_taskbar_hint" },
    .{ "gtk_window_set_modal", "gtk_window_set_modal" },
    .{ "gtk_window_set_transient_for", "gtk_window_set_transient_for" },
    .{ "gtk_window_set_position", "gtk_window_set_position" },
    .{ "gtk_window_move", "gtk_window_move" },
    .{ "gtk_window_resize", "gtk_window_resize" },
    .{ "gtk_window_get_size", "gtk_window_get_size" },
    .{ "gtk_window_get_position", "gtk_window_get_position" },
    .{ "gtk_window_iconify", "gtk_window_iconify" },
    .{ "gtk_window_deiconify", "gtk_window_deiconify" },
    .{ "gtk_window_maximize", "gtk_window_maximize" },
    .{ "gtk_window_unmaximize", "gtk_window_unmaximize" },
    .{ "gtk_window_fullscreen", "gtk_window_fullscreen" },
    .{ "gtk_window_unfullscreen", "gtk_window_unfullscreen" },
    .{ "gtk_window_set_geometry_hints", "gtk_window_set_geometry_hints" },
    .{ "gtk_window_set_default_icon_name", "gtk_window_set_default_icon_name" },
    .{ "gtk_status_icon_new_from_icon_name", "gtk_status_icon_new_from_icon_name" },
    .{ "gtk_status_icon_set_tooltip_text", "gtk_status_icon_set_tooltip_text" },
    .{ "gtk_status_icon_set_visible", "gtk_status_icon_set_visible" },
    .{ "gtk_status_icon_is_embedded", "gtk_status_icon_is_embedded" },
    .{ "gtk_menu_bar_new", "gtk_menu_bar_new" },
    .{ "gtk_menu_new", "gtk_menu_new" },
    .{ "gtk_menu_item_new_with_label", "gtk_menu_item_new_with_label" },
    .{ "gtk_menu_item_new_with_mnemonic", "gtk_menu_item_new_with_mnemonic" },
    .{ "gtk_menu_item_set_submenu", "gtk_menu_item_set_submenu" },
    .{ "gtk_menu_item_set_label", "gtk_menu_item_set_label" },
    .{ "gtk_menu_shell_append", "gtk_menu_shell_append" },
    .{ "gtk_separator_menu_item_new", "gtk_separator_menu_item_new" },
    .{ "gtk_check_menu_item_new_with_label", "gtk_check_menu_item_new_with_label" },
    .{ "gtk_check_menu_item_set_active", "gtk_check_menu_item_set_active" },
    .{ "gtk_check_menu_item_get_active", "gtk_check_menu_item_get_active" },
    .{ "gtk_box_pack_start", "gtk_box_pack_start" },
    .{ "gtk_widget_set_sensitive", "gtk_widget_set_sensitive" },
    .{ "gtk_accel_group_new", "gtk_accel_group_new" },
    .{ "gtk_window_add_accel_group", "gtk_window_add_accel_group" },
    .{ "gtk_widget_add_accelerator", "gtk_widget_add_accelerator" },
    .{ "gtk_clipboard_get", "gtk_clipboard_get" },
    .{ "gtk_clipboard_wait_for_text", "gtk_clipboard_wait_for_text" },
    .{ "gtk_clipboard_set_text", "gtk_clipboard_set_text" },
    .{ "gtk_clipboard_store", "gtk_clipboard_store" },
    .{ "gtk_file_chooser_dialog_new", "gtk_file_chooser_dialog_new" },
    .{ "gtk_file_chooser_set_select_multiple", "gtk_file_chooser_set_select_multiple" },
    .{ "gtk_file_chooser_set_current_name", "gtk_file_chooser_set_current_name" },
    .{ "gtk_file_chooser_get_filename", "gtk_file_chooser_get_filename" },
    .{ "gtk_file_chooser_get_filenames", "gtk_file_chooser_get_filenames" },
    .{ "gtk_file_chooser_add_filter", "gtk_file_chooser_add_filter" },
    .{ "gtk_file_filter_new", "gtk_file_filter_new" },
    .{ "gtk_file_filter_set_name", "gtk_file_filter_set_name" },
    .{ "gtk_file_filter_add_pattern", "gtk_file_filter_add_pattern" },
    .{ "gtk_dialog_run", "gtk_dialog_run" },
    .{ "gtk_dialog_add_button", "gtk_dialog_add_button" },
    .{ "gtk_message_dialog_new", "gtk_message_dialog_new" },
    .{ "gtk_show_uri_on_window", "gtk_show_uri_on_window" },
    .{ "gtk_window_set_type_hint", "gtk_window_set_type_hint" },
    .{ "gtk_window_present", "gtk_window_present" },
    .{ "gtk_widget_show", "gtk_widget_show" },
    .{ "gtk_widget_show_all", "gtk_widget_show_all" },
    .{ "gtk_widget_hide", "gtk_widget_hide" },
    .{ "gtk_widget_destroy", "gtk_widget_destroy" },
    .{ "gtk_widget_grab_focus", "gtk_widget_grab_focus" },
    .{ "gtk_widget_queue_draw", "gtk_widget_queue_draw" },
    .{ "gtk_widget_set_can_focus", "gtk_widget_set_can_focus" },
    .{ "gtk_widget_add_events", "gtk_widget_add_events" },
    .{ "gtk_box_new", "gtk_box_new" },
    .{ "gtk_drawing_area_new", "gtk_drawing_area_new" },
    .{ "gtk_event_box_new", "gtk_event_box_new" },
    .{ "gtk_widget_get_pointer", "gtk_widget_get_pointer" },
    .{ "gtk_widget_set_size_request", "gtk_widget_set_size_request" },

    .{ "gtk_container_add", "gtk_container_add" },
    .{ "gtk_widget_get_parent", "gtk_widget_get_parent" },
    .{ "gtk_container_remove", "gtk_container_remove" },
    .{ "gtk_events_pending", "gtk_events_pending" },
    .{ "gtk_main", "gtk_main" },
    .{ "gtk_main_iteration_do", "gtk_main_iteration_do" },
    .{ "gtk_main_quit", "gtk_main_quit" },
    .{ "gtk_settings_get_default", "gtk_settings_get_default" },
    .{ "gtk_style_context_new", "gtk_style_context_new" },
    .{ "gtk_window_set_default_icon_from_file", "gtk_window_set_default_icon_from_file" },
};

const webkit_syms = .{
    .{ "webkit_web_view_new_with_user_content_manager", "webkit_web_view_new_with_user_content_manager" },
    .{ "webkit_user_content_manager_new", "webkit_user_content_manager_new" },
    .{ "webkit_user_content_manager_register_script_message_handler", "webkit_user_content_manager_register_script_message_handler" },
    .{ "webkit_user_content_manager_add_script", "webkit_user_content_manager_add_script" },
    .{ "webkit_user_script_new", "webkit_user_script_new" },
    .{ "webkit_user_script_unref", "webkit_user_script_unref" },
    .{ "webkit_web_view_load_uri", "webkit_web_view_load_uri" },
    .{ "webkit_web_view_load_html", "webkit_web_view_load_html" },
    .{ "webkit_web_view_run_javascript", "webkit_web_view_run_javascript" },
    .{ "webkit_web_view_get_title", "webkit_web_view_get_title" },
    .{ "webkit_web_view_get_uri", "webkit_web_view_get_uri" },
    .{ "webkit_web_view_reload", "webkit_web_view_reload" },
    .{ "webkit_web_view_go_back", "webkit_web_view_go_back" },
    .{ "webkit_web_view_go_forward", "webkit_web_view_go_forward" },
    .{ "webkit_web_view_can_go_back", "webkit_web_view_can_go_back" },
    .{ "webkit_web_view_can_go_forward", "webkit_web_view_can_go_forward" },
    .{ "webkit_web_view_set_background_color", "webkit_web_view_set_background_color" },
    .{ "webkit_web_view_set_zoom_level", "webkit_web_view_set_zoom_level" },
    .{ "webkit_web_view_get_zoom_level", "webkit_web_view_get_zoom_level" },
    .{ "webkit_web_view_get_settings", "webkit_web_view_get_settings" },
    .{ "webkit_web_view_get_inspector", "webkit_web_view_get_inspector" },
    .{ "webkit_web_inspector_show", "webkit_web_inspector_show" },
    .{ "webkit_web_view_get_user_content_manager", "webkit_web_view_get_user_content_manager" },
    .{ "webkit_settings_set_enable_developer_extras", "webkit_settings_set_enable_developer_extras" },
    .{ "webkit_settings_set_enable_javascript", "webkit_settings_set_enable_javascript" },
    .{ "webkit_settings_set_enable_write_console_messages_to_stdout", "webkit_settings_set_enable_write_console_messages_to_stdout" },
    .{ "webkit_settings_set_enable_smooth_scrolling", "webkit_settings_set_enable_smooth_scrolling" },
    .{ "webkit_settings_set_hardware_acceleration_policy", "webkit_settings_set_hardware_acceleration_policy" },
    .{ "webkit_settings_set_user_agent", "webkit_settings_set_user_agent" },
    .{ "webkit_security_manager_register_uri_scheme_as_cors_enabled", "webkit_security_manager_register_uri_scheme_as_cors_enabled" },
    .{ "webkit_security_manager_register_uri_scheme_as_secure", "webkit_security_manager_register_uri_scheme_as_secure" },
    .{ "webkit_web_context_get_default", "webkit_web_context_get_default" },
    .{ "webkit_web_context_get_security_manager", "webkit_web_context_get_security_manager" },
    .{ "webkit_web_context_register_uri_scheme", "webkit_web_context_register_uri_scheme" },
    .{ "webkit_web_context_set_cache_model", "webkit_web_context_set_cache_model" },
    .{ "webkit_web_context_clear_cache", "webkit_web_context_clear_cache" },
    .{ "webkit_uri_scheme_request_get_uri", "webkit_uri_scheme_request_get_uri" },
    .{ "webkit_uri_scheme_request_get_path", "webkit_uri_scheme_request_get_path" },
    .{ "webkit_uri_scheme_request_get_http_method", "webkit_uri_scheme_request_get_http_method" },
    .{ "webkit_uri_scheme_request_finish", "webkit_uri_scheme_request_finish" },
    .{ "webkit_uri_scheme_request_finish_error", "webkit_uri_scheme_request_finish_error" },
    .{ "webkit_web_view_terminate_web_process", "webkit_web_view_terminate_web_process" },
    .{ "webkit_web_view_get_estimated_load_progress", "webkit_web_view_get_estimated_load_progress" },
    .{ "webkit_javascript_result_get_js_value", "webkit_javascript_result_get_js_value" },
    .{ "webkit_javascript_result_unref", "webkit_javascript_result_unref" },
    .{ "webkit_navigation_action_get_request", "webkit_navigation_action_get_request" },
    .{ "webkit_uri_request_get_uri", "webkit_uri_request_get_uri" },
    .{ "webkit_policy_decision_ignore", "webkit_policy_decision_ignore" },
    .{ "webkit_navigation_policy_decision_get_navigation_action", "webkit_navigation_policy_decision_get_navigation_action" },
    .{ "webkit_navigation_action_is_user_gesture", "webkit_navigation_action_is_user_gesture" },
    .{ "webkit_web_view_load_bytes", "webkit_web_view_load_bytes" },
    .{ "webkit_web_view_call_async_javascript_function", "webkit_web_view_call_async_javascript_function" },
};

// ----------------------------------------------------------------- helpers

pub const cstr_max = 4096;

/// A stack buffer holding a NUL-terminated copy of `s`. Truncates if `s` is
/// longer than `cstr_max - 1`.
/// Copies `s` into a NUL-terminated allocation from `allocator`. Use this
/// instead of `CStr` for anything whose length is not bounded by the caller:
/// `CStr` truncates, which is correct for a window title and catastrophic for a
/// script.
pub fn dupeCStr(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

pub const CStr = struct {
    buf: [cstr_max]u8 = undefined,
    len: usize = 0,

    pub fn init(s: []const u8) CStr {
        var self = CStr{};
        const n = @min(s.len, cstr_max - 1);
        @memcpy(self.buf[0..n], s[0..n]);
        self.buf[n] = 0;
        self.len = n;
        return self;
    }

    pub fn ptr(self: *const CStr) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }

    pub fn slice(self: *const CStr) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Copies a C string into `buf`. Returns an empty slice for null.
pub fn copyCStr(buf: []u8, p: ?[*:0]const u8) []const u8 {
    const src = p orelse return "";
    const n = std.mem.len(src);
    const len = @min(n, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    return buf[0..len];
}

/// Releases a string returned by a GTK getter (transfer full: a copy).
pub fn freeString(p: ?[*:0]u8) void {
    if (p) |s| g_free(@ptrCast(s));
}

/// Connects a signal. `cb` must be a C-callable function pointer created with
/// `makeSignalCallback` or a Zig `callconv(.c)` function.
pub fn connectSignal(obj: ?gpointer, signal: [*:0]const u8, cb: *const anyopaque, data: ?gpointer) gulong {
    return g_signal_connect_data(obj, signal, cb, data, null, 0);
}

/// A callback created for a particular window. One is created per window and
/// per signal, never per call, and is freed with the window.
pub const SignalCallback = *const anyopaque;

/// GTK needs an argv it may modify; MyZig gives it its own program name and
/// nothing else, because GTK's option parser would reject the app's flags.
var init_argv_storage: [2][*c]u8 = undefined;
var init_prog_name: [1:0]u8 = .{0};

/// Initialises GTK, ignoring the process' arguments.
pub fn gtkInit() gboolean {
    var argc: c_int = 1;
    var argv: [*c][*c]u8 = @ptrCast(&init_argv_storage);
    init_argv_storage[0] = @ptrCast(&init_prog_name);
    init_argv_storage[1] = null;
    return gtk_init_check(&argc, &argv);
}

/// Whether the session runs Wayland. GTK picks the backend; this only informs
/// the messages and the platform differences.
pub fn isWayland() bool {
    const wl = env.get("WAYLAND_DISPLAY") orelse "";
    const session = env.get("XDG_SESSION_TYPE") orelse "";
    return wl.len > 0 or std.mem.eql(u8, session, "wayland");
}

/// Parses `#rrggbb` or `#rrggbbaa` into a GdkRGBA. Returns a fallback for
/// other syntaxes.
pub fn parseColor(s: []const u8) GdkRGBA {
    const fallback = GdkRGBA{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
    var hex = s;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len != 6 and hex.len != 8) return fallback;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return fallback;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return fallback;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return fallback;
    const a: u8 = if (hex.len == 8) (std.fmt.parseInt(u8, hex[6..8], 16) catch 255) else 255;
    return .{
        .red = @as(f64, @floatFromInt(r)) / 255,
        .green = @as(f64, @floatFromInt(g)) / 255,
        .blue = @as(f64, @floatFromInt(b)) / 255,
        .alpha = @as(f64, @floatFromInt(a)) / 255,
    };
}

/// Splits `0xRRGGBBAA` from the framework's window options into a GdkRGBA.
pub fn rgbaFromPacked(value: u32) GdkRGBA {
    return .{
        .red = @as(f64, @floatFromInt((value >> 24) & 0xff)) / 255,
        .green = @as(f64, @floatFromInt((value >> 16) & 0xff)) / 255,
        .blue = @as(f64, @floatFromInt((value >> 8) & 0xff)) / 255,
        .alpha = @as(f64, @floatFromInt(value & 0xff)) / 255,
    };
}

// GtkWindowType
pub const GTK_WINDOW_TOPLEVEL: c_int = 0;
pub const GTK_WINDOW_POPUP: c_int = 1;
// GtkWindowPosition
pub const GTK_WIN_POS_NONE: c_int = 0;
pub const GTK_WIN_POS_CENTER: c_int = 1;
// GtkWindowTypeHint
pub const GDK_WINDOW_TYPE_HINT_NORMAL: c_int = 0;
pub const GDK_WINDOW_TYPE_HINT_DIALOG: c_int = 1;
pub const GDK_WINDOW_TYPE_HINT_UTILITY: c_int = 2;
// GtkOrientation
// WebKitUserScriptInjectionTime
pub const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START: c_int = 0;
pub const WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END: c_int = 1;
// WebKitUserContentInjectedFrames
pub const WEBKIT_USER_CONTENT_INJECT_TOP_FRAME: c_int = 1;
pub const WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES: c_int = 0;
// WebKitHardwareAccelerationPolicy
pub const WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS: c_int = 0;
pub const WEBKIT_HARDWARE_ACCELERATION_POLICY_ON_DEMAND: c_int = 2;
// WebKitCacheModel
pub const WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER: c_int = 0;
pub const WEBKIT_CACHE_MODEL_WEB_BROWSER: c_int = 1;

// GDK event masks
pub const GDK_BUTTON_PRESS_MASK: gint = 1 << 8;
pub const GDK_BUTTON_RELEASE_MASK: gint = 1 << 9;
pub const GDK_POINTER_MOTION_MASK: gint = 1 << 6;
pub const GDK_SCROLL_MASK: gint = 1 << 21;
pub const GDK_KEY_PRESS_MASK: gint = 1 << 0;
pub const GDK_KEY_RELEASE_MASK: gint = 1 << 1;
pub const GDK_FOCUS_CHANGE_MASK: gint = 1 << 12;
pub const GDK_STRUCTURE_MASK: gint = 1 << 4;
pub const GDK_SMOOTH_SCROLL_MASK: gint = 1 << 23;

test "color parsing" {
    const c = parseColor("#ff8000");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c.red, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 128.0 / 255.0), c.green, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c.blue, 1e-9);

    const with_alpha = parseColor("#00000080");
    try std.testing.expectApproxEqAbs(@as(f64, 128.0 / 255.0), with_alpha.alpha, 1e-9);

    const bad = parseColor("rgb(1,2,3)");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bad.red, 1e-9);
}

test "packed rgba" {
    const c = rgbaFromPacked(0x11223344);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(@as(u32, 0x11))) / 255.0, c.red, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(@as(u32, 0x44))) / 255.0, c.alpha, 1e-9);
}

test "CStr is nul terminated" {
    const c = CStr.init("hello");
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(c.ptr(), 0));
    try std.testing.expectEqualStrings("hello", c.slice());
}

test "CStr truncates long input" {
    var buf_long: [cstr_max + 10]u8 = @splat('x');
    const long: []const u8 = &buf_long;
    const c = CStr.init(long);
    try std.testing.expectEqual(cstr_max - 1, c.len);
    try std.testing.expectEqual(@as(u8, 0), c.buf[c.len]);
}

//! WebKitGTK web views.
//!
//! One `WebKitWebView` per page-showing window, with a `WebKitUserContentManager`
//! that:
//!
//! * registers the `myzig` script message handler the page's bridge posts to,
//! * injects the bridge script at document start into the top frame only.
//!
//! The IPC wire format and the bridge source live in `src/ipc` and
//! `src/webview`; this file only transports strings.
//!
//! ## Lifetime
//!
//! The web view belongs to its `GtkWindow`, which destroys it. The registry
//! below maps a window id to the native handle for signalling, and holds no
//! ownership. Callbacks are created once for the whole process and route by the
//! window id in their user data.

const std = @import("std");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");
const log = @import("../../log.zig");
const ffi = @import("ffi.zig");
const bridge = @import("../../webview/bridge.zig");
const scheme = @import("scheme.zig");

pub const Error = error{ OutOfMemory, NotSupported };

const View = struct {
    id: u32,
    web: ffi.WebKitWebView,
    ucm: ffi.WebKitUserContentManager,
    secret: u64,
    pending_url: []const u8 = "",
};

var views: std.AutoHashMapUnmanaged(u32, View) = .empty;
var gpa: std.mem.Allocator = undefined;
var sink: ?backend.EventSink = null;
var host_app: ?*app_mod.App = null;
var callbacks_ready = false;

var msg_cb: ?*const anyopaque = null;
var load_changed_cb: ?*const anyopaque = null;
var load_failed_cb: ?*const anyopaque = null;
var title_cb: ?*const anyopaque = null;
var uri_cb: ?*const anyopaque = null;
var decide_policy_cb: ?*const anyopaque = null;

pub fn init(allocator: std.mem.Allocator, events_sink: backend.EventSink, app: *app_mod.App) void {
    gpa = allocator;
    sink = events_sink;
    host_app = app;
    ensureCallbacks();
}

pub fn shutdownAll() void {
    views.deinit(gpa);
    views = .empty;
}

fn dataInt(data: ?*anyopaque) u32 {
    return @truncate(@intFromPtr(data));
}
fn dataPtr(id: u32) ?*anyopaque {
    return @ptrFromInt(@as(usize, id));
}

fn ensureCallbacks() void {
    if (callbacks_ready) return;
    callbacks_ready = true;

    // WKScriptMessageHandler's callback: (ucm, js_value, user_data).
    msg_cb = @ptrCast(&struct {
        fn cb(ucm: *anyopaque, value: *anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = ucm;
            onMessage(dataInt(data), value);
        }
    }.cb);

    load_changed_cb = @ptrCast(&struct {
        // GObject passes a `WebKitLoadEvent` (a GEnum) by value, so the second
        // argument is an integer, not a pointer.
        fn cb(web: *anyopaque, event: c_int, data: ?*anyopaque) callconv(.c) void {
            _ = web;
            onLoadChanged(dataInt(data), event);
        }
    }.cb);

    load_failed_cb = @ptrCast(&struct {
        fn cb(web: *anyopaque, event: *anyopaque, uri: ?[*:0]const u8, err: *anyopaque, data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = web;
            _ = event;
            _ = uri;
            _ = err;
            onLoadFailed(dataInt(data));
            return ffi.FALSE;
        }
    }.cb);

    title_cb = @ptrCast(&struct {
        fn cb(web: *anyopaque, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = web;
            onTitleChanged(dataInt(data));
        }
    }.cb);

    uri_cb = @ptrCast(&struct {
        fn cb(web: *anyopaque, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = web;
            onUriChanged(dataInt(data));
        }
    }.cb);

    decide_policy_cb = @ptrCast(&struct {
        fn cb(web: *anyopaque, action: *anyopaque, decision_type: c_int, data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = web;
            // TRUE means "the default handler ran", which suppresses the
            // navigation; the framework cancels by returning TRUE here.
            return if (onDecidePolicy(dataInt(data), action, decision_type)) ffi.TRUE else ffi.FALSE;
        }
    }.cb);

}

// ------------------------------------------------------------------- create

pub fn createFor(id: u32, parent: ffi.GtkWindow, opts: backend.WindowOptions) Error!ffi.WebKitWebView {
    _ = parent;
    // The custom scheme must exist before the first web view, or WebKit treats
    // `myzig://` as an unknown protocol and refuses to load it.
    if (host_app) |a| scheme.install(a);
    // The message handler reads its argument through JavaScriptCore, so that
    // library must be resolved before the first message can arrive.
    loadJsCore();
    const ucm = ffi.webkit_user_content_manager_new() orelse return error.NotSupported;

    // Inject the IPC bridge before any page script runs, in the top frame only:
    // an iframe of another origin must not be able to reach the framework.
    const script_src = bridge.scriptWithConfig(gpa, opts.secret, id) catch return error.OutOfMemory;
    defer gpa.free(script_src);

    {
        // The bridge is a few kilobytes, so it is copied into an owned
        // NUL-terminated buffer rather than a fixed stack one.
        const src = ffi.dupeCStr(gpa, script_src) catch return error.OutOfMemory;
        defer gpa.free(src);
        log.debug("bridge script: {d} bytes, first newline at {d}", .{
            src.len,
            std.mem.indexOfScalar(u8, src, '\n') orelse 0,
        });
        const script = ffi.webkit_user_script_new(
            src.ptr,
            ffi.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
            ffi.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
            null,
            null,
        );
        if (script) |sc| {
            // `webkit_user_script_new` is transfer-full and `add_script`
            // takes its own reference, so the one we own is released here.
            ffi.webkit_user_content_manager_add_script(ucm, sc);
            ffi.webkit_user_script_unref(sc);
        }
    }

    _ = ffi.webkit_user_content_manager_register_script_message_handler(ucm, bridge.message_handler_name);
    _ = ffi.connectSignal(@ptrCast(ucm), "script-message-received::" ++ bridge.message_handler_name, msg_cb.?, dataPtr(id));

    const web = ffi.webkit_web_view_new_with_user_content_manager(ucm) orelse return error.NotSupported;

    _ = ffi.g_object_ref_sink(@ptrCast(ucm));

    // `gpointer` is already optional in ffi.zig, so this binds directly
    // without a second `orelse`.
    if (ffi.webkit_web_view_get_settings(web)) |st| {
        ffi.webkit_settings_set_enable_javascript(st, ffi.TRUE);
        ffi.webkit_settings_set_enable_developer_extras(st, ffi.TRUE);
        ffi.webkit_settings_set_enable_smooth_scrolling(st, ffi.TRUE);
        // A page's console output is the developer's only window into the
        // JavaScript side, so it goes to the terminal rather than nowhere.
        ffi.webkit_settings_set_enable_write_console_messages_to_stdout(st, ffi.TRUE);
        ffi.webkit_settings_set_hardware_acceleration_policy(st, ffi.WEBKIT_HARDWARE_ACCELERATION_POLICY_ON_DEMAND);
    }

    {
        const bg = ffi.rgbaFromPacked(opts.background);
        ffi.webkit_web_view_set_background_color(web, &bg);
    }

    _ = ffi.connectSignal(@ptrCast(web), "load-changed", load_changed_cb.?, dataPtr(id));
    _ = ffi.connectSignal(@ptrCast(web), "load-failed", load_failed_cb.?, dataPtr(id));
    _ = ffi.connectSignal(@ptrCast(web), "notify::title", title_cb.?, dataPtr(id));
    _ = ffi.connectSignal(@ptrCast(web), "notify::uri", uri_cb.?, dataPtr(id));
    _ = ffi.connectSignal(@ptrCast(web), "decide-policy", decide_policy_cb.?, dataPtr(id));
    // Console output is routed to the framework log through the settings flag
    // rather than a per-message signal, which costs nothing when unused.

    views.put(gpa, id, .{ .id = id, .web = web, .ucm = ucm, .secret = opts.secret }) catch return error.OutOfMemory;
    return web;
}

/// Loads the window's initial URL once the view is in its window.
pub fn startPage(id: u32, url: []const u8) void {
    if (url.len == 0) return;
    _ = loadUrl(id, url);
}

pub fn loadUrl(id: u32, url: []const u8) bool {
    const v = views.getPtr(id) orelse return false;
    const c = ffi.CStr.init(url);
    ffi.webkit_web_view_load_uri(v.web, c.ptr());
    return true;
}

pub fn loadHtml(id: u32, html: []const u8, base: []const u8) bool {
    const v = views.getPtr(id) orelse return false;
    const h = ffi.CStr.init(html);
    const b = ffi.CStr.init(base);
    ffi.webkit_web_view_load_html(v.web, h.ptr(), b.ptr());
    return true;
}

pub fn eval(id: u32, code: []const u8) bool {
    const v = views.getPtr(id) orelse return false;
    const c = ffi.dupeCStr(gpa, code) catch return false;
    defer gpa.free(c);
    ffi.webkit_web_view_run_javascript(v.web, c.ptr, null, null, null);
    return true;
}

pub fn inject(id: u32, code: []const u8) bool {
    const v = views.getPtr(id) orelse return false;
    const c = ffi.dupeCStr(gpa, code) catch return false;
    defer gpa.free(c);
    const script = ffi.webkit_user_script_new(
        c.ptr,
        ffi.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        ffi.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        null,
        null,
    );
    const sc = script orelse return false;
    ffi.webkit_user_content_manager_add_script(v.ucm, sc);
    ffi.webkit_user_script_unref(sc);
    return true;
}

pub fn openDevtools(id: u32) void {
    const v = views.getPtr(id) orelse return;
    const inspector = ffi.webkit_web_view_get_inspector(v.web) orelse return;
    ffi.webkit_web_inspector_show(inspector);
}

pub fn reload(id: u32) void {
    const v = views.getPtr(id) orelse return;
    ffi.webkit_web_view_reload(v.web);
}

// ------------------------------------------------------------------ signals

/// `WebKitLoadEvent`: 0 started, 1 redirect, 2 committed, 3 finished.
fn onLoadChanged(id: u32, kind: c_int) void {
    const s = sink orelse return;
    switch (kind) {
        0 => s.webLoadStarted(id),
        2 => s.webDomReady(id),
        3 => s.webLoadFinished(id),
        else => {},
    }
}

fn onLoadFailed(id: u32) void {
    if (sink) |s| s.webLoadFailed(id, "load failed");
}

fn onTitleChanged(id: u32) void {
    const v = views.getPtr(id) orelse return;
    var buf: [512]u8 = undefined;
    // `get_title` is transfer-none: the string belongs to the web view and must
    // not be freed here.
    const title = ffi.copyCStr(&buf, ffi.webkit_web_view_get_title(v.web));
    if (sink) |s| s.webTitleChanged(id, title);
}

fn onUriChanged(id: u32) void {
    const v = views.getPtr(id) orelse return;
    var buf: [2048]u8 = undefined;
    // `get_uri` is transfer-none as well.
    const uri = ffi.copyCStr(&buf, ffi.webkit_web_view_get_uri(v.web));
    if (sink) |s| s.webUrlChanged(id, uri);
}

fn onMessage(id: u32, value: *anyopaque) void {
    const v = views.getPtr(id) orelse return;
    _ = v;
    // The message is a JSCValue holding the string the bridge posted. WebKitGTK
    // hands it as the signal's JSCValue argument; read it as a UTF-8 string
    // through JavaScriptCore, which WebKitGTK links.
    const s = sink orelse return;
    var buf: [1 << 16]u8 = undefined;
    const text = readMessage(&buf, value) orelse return;
    s.webMessage(id, text);
}

/// Reads a page message.
///
/// WebKitGTK delivers a `script-message-received::<name>` argument as a
/// `WebKitJavascriptResult`, not a `JSCValue`: the value must be unwrapped
/// first. The result is transferred to the handler and released here.
fn readMessage(buf: []u8, result: *anyopaque) ?[]const u8 {
    defer ffi.webkit_javascript_result_unref(result);
    const value = ffi.webkit_javascript_result_get_js_value(result) orelse return null;
    return jscString(buf, value);
}

/// Reads a JSCValue string. `jsc_value_to_string` returns UTF-8 owned by
/// JavaScriptCore; `g_free` releases it.
fn jscString(buf: []u8, value: *anyopaque) ?[]const u8 {
    const jsc = js_core orelse return null;
    const raw = jsc.to_string(value) orelse return null;
    defer ffi.g_free(@ptrCast(raw));
    const n = std.mem.len(raw);
    if (n > buf.len) return null;
    @memcpy(buf[0..n], raw[0..n]);
    return buf[0..n];
}

const JsCore = struct {
    to_string: *const fn (value: *anyopaque) callconv(.c) ?[*:0]u8,
};

var js_core: ?JsCore = null;
var js_core_loaded = false;
/// Held open for the process lifetime: a symbol looked up from a `DynLib`
/// becomes invalid the moment the library is closed.
var js_core_lib: ?std.DynLib = null;

pub fn loadJsCore() void {
    if (js_core_loaded) return;
    js_core_loaded = true;
    var lib = std.DynLib.open("libjavascriptcoregtk-4.1.so.0") catch |e| blk: {
        log.debug("ipc: cannot open JavaScriptCore 4.1: {s}", .{@errorName(e)});
        break :blk std.DynLib.open("libjavascriptcoregtk-4.0.so.37") catch |e2| {
            log.debug("ipc: cannot open JavaScriptCore 4.0 either: {s}", .{@errorName(e2)});
            return;
        };
    };
    const f = lib.lookup(*const fn (value: *anyopaque) callconv(.c) ?[*:0]u8, "jsc_value_to_string") orelse {
        log.debug("ipc: jsc_value_to_string is missing", .{});
        return;
    };
    js_core = .{ .to_string = f };
    js_core_lib = lib;
}

/// `WebKitPolicyDecisionType`: 0 navigation-action, 1 new-window-action,
/// 2 response.
///
/// The second signal argument is a `WebKitPolicyDecision`. Only a navigation
/// action carries a URI request; the others are passed through untouched.
fn onDecidePolicy(id: u32, decision: *anyopaque, decision_type: c_int) bool {
    if (decision_type != 0) return false;
    const s = sink orelse return false;

    const nav = ffi.webkit_navigation_policy_decision_get_navigation_action(decision) orelse return false;
    const req = ffi.webkit_navigation_action_get_request(nav) orelse return false;
    var buf: [2048]u8 = undefined;
    const raw = ffi.webkit_uri_request_get_uri(req);
    const uri = ffi.copyCStr(&buf, raw);

    if (s.webNavigationRequested(id, uri)) return false;
    // The framework declined this navigation, so the decision is settled here.
    ffi.webkit_policy_decision_ignore(decision);
    return true;
}

test "view registry starts empty" {
    try std.testing.expectEqual(@as(usize, 0), views.count());
}

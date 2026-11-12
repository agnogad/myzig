//! The `myzig://` scheme.
//!
//! A window whose URL uses `myzig://` is served from the application's embedded
//! frontend, not from disk or the network. That gives production builds one
//! file to ship, a real origin for the page (`myzig://app`), and no local HTTP
//! server to secure.
//!
//! ## Registration order
//!
//! The scheme must be registered with WebKit **before** any web view exists.
//! MyZig registers it once, lazily, the first time a page-showing window is
//! created, and marks it `secure` so the page gets a normal, non-opaque origin
//! and can use storage APIs.
//!
//! ## Lookup
//!
//! The path is resolved against the app's frontend table with a small, fixed
//! rule set:
//!
//! * `/` alone resolves to `index.html`.
//! * A path is used as given; `..` segments are rejected, so a page cannot
//!   escape the embedded set.
//! * An unknown path answers 404 rather than a blank page, so a missing asset
//!   is visible in the inspector.

const std = @import("std");
const ffi = @import("ffi.zig");
const log = @import("../../log.zig");
const errors = @import("../../errors.zig");
const app_mod = @import("../../app.zig");

/// The scheme the application's bundle is served from.
pub const scheme = "myzig";

var registered = false;
var host_app: ?*app_mod.App = null;
var handler_cb: ?*const anyopaque = null;

fn ensureCallback() void {
    if (handler_cb != null) return;
    handler_cb = @ptrCast(&struct {
        // `WebKitURISchemeRequestCallback`: (request, user_data)
        fn cb(request: *anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = data;
            onRequest(request);
        }
    }.cb);
}

/// Registers `myzig://` on the default web context. Idempotent.
pub fn install(app: *app_mod.App) void {
    if (registered) return;
    host_app = app;
    ensureCallback();

    const context = ffi.webkit_web_context_get_default() orelse {
        log.err("WebKit has no default context", .{});
        return;
    };
    const name = ffi.CStr.init(scheme);
    ffi.webkit_web_context_register_uri_scheme(context, name.ptr(), handler_cb.?, null, null);

    // A secure scheme gets a real origin, so `localStorage`, `fetch` to the same
    // scheme and modules behave the way a page expects.
    if (ffi.webkit_web_context_get_security_manager(context)) |sm| {
        ffi.webkit_security_manager_register_uri_scheme_as_secure(sm, name.ptr());
        ffi.webkit_security_manager_register_uri_scheme_as_cors_enabled(sm, name.ptr());
    }
    registered = true;
}

fn onRequest(request: *anyopaque) void {
    const app = host_app orelse return;
    // Two buffers: `raw` receives the C string, `clean` receives the
    // normalized key. They must not be the same slice, because `normalize`
    // copies into its output while reading its input.
    var raw: [1024]u8 = undefined;
    var clean: [1024]u8 = undefined;
    const path_c = ffi.webkit_uri_scheme_request_get_path(request);
    const path = normalize(&clean, ffi.copyCStr(&raw, path_c));

    const file = app.frontendFile(path) orelse {
        log.debug("myzig:// miss: {s}", .{path});
        respondError(request, 404);
        return;
    };
    respond(request, file.data, file.mime);
}

/// Maps a URL path onto a frontend key.
///
/// Returns an empty slice for a path that tries to escape the bundle, which the
/// caller reports as not found.
fn normalize(buf: []u8, raw: []const u8) []const u8 {
    var path = raw;
    while (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len == 0) {
        const index = "index.html";
        if (index.len > buf.len) return "";
        @memcpy(buf[0..index.len], index);
        return buf[0..index.len];
    }
    if (path.len > buf.len) return "";
    @memcpy(buf[0..path.len], path);
    const p = buf[0..path.len];
    // Reject any traversal: the bundle is a flat namespace, so `..` is never
    // legitimate.
    if (std.mem.indexOf(u8, p, "..") != null) return "";
    return p;
}

fn respond(request: *anyopaque, data: []const u8, mime: []const u8) void {
    // The bytes live in the app's arena, which outlives the request, so a
    // static GBytes references them without copying and without taking
    // ownership: nothing is freed when the stream is released.
    const bytes = ffi.g_bytes_new_static(data.ptr, data.len) orelse {
        respondError(request, 500);
        return;
    };
    defer ffi.g_bytes_unref(bytes);
    const stream = ffi.g_memory_input_stream_new_from_bytes(bytes) orelse {
        respondError(request, 500);
        return;
    };
    defer ffi.g_object_unref(@ptrCast(stream));
    const m = ffi.CStr.init(mime);
    ffi.webkit_uri_scheme_request_finish(request, stream, @intCast(data.len), m.ptr());
}

fn respondError(request: *anyopaque, code: u16) void {
    var err = ffi.GErrorFull{
        .domain = ffi.g_quark_from_static_string("myzig-scheme"),
        .code = @intCast(code),
        .message = null,
    };
    ffi.webkit_uri_scheme_request_finish_error(request, &err);
}

test "paths normalize to frontend keys" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("index.html", normalize(&buf, ""));
    try std.testing.expectEqualStrings("index.html", normalize(&buf, "/"));
    try std.testing.expectEqualStrings("a/b.js", normalize(&buf, "/a/b.js"));
    try std.testing.expectEqualStrings("", normalize(&buf, "/../etc/passwd"));
    try std.testing.expectEqualStrings("", normalize(&buf, "/a/../../b"));
}

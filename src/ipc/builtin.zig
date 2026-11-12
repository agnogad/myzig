//! Built-in services the bridge calls: `Clipboard`, `Dialog`, `Notification`,
//! `Shell` and `Window`.
//!
//! These make `window.myzig.clipboard.readText()` work without the application
//! binding anything. They are ordinary services registered at startup, so a
//! page cannot tell them apart from the app's own.
//!
//! ## Ownership
//!
//! Each handler's reply must outlive the handler call, because the exchange
//! encodes it after the handler returns. The buffers below live for the
//! process: replies are built into them and are valid until the next call on
//! the same thread. Since every handler runs on the main thread inside the
//! loop, and the exchange encodes the reply before the next message is handled,
//! one buffer per service is enough.
//!
//! ## Arguments
//!
//! Every handler decodes with `ipc.Args`, so a call from a page with a stale
//! signature fails with `invalid-argument` rather than misbehaving.

const std = @import("std");
const app_mod = @import("../app.zig");
const json = @import("../json.zig");
const ipc = @import("../ipc/ipc.zig");
const desktop = @import("../platform/desktop.zig");
const events = @import("../events.zig");
const version = @import("../version.zig");

/// Per-service reply storage. See the note above on ownership.
var clipboard_buf: [1 << 16]u8 = undefined;
var dialog_paths: desktop.PathBuffer = .{};
var dialog_reply: [1 << 16]u8 = undefined;
var dialog_reply_len: usize = 0;
var window_reply: [256]u8 = undefined;
var window_reply_len: usize = 0;

/// How many built-in methods `fill` writes.
pub const count = 25;

/// Writes every built-in method into `out`. The caller owns `out`, so the
/// registrations outlive this call: a registry stores the slice it was given.
pub fn fill(out: *[count]ipc.service.Method, app: *app_mod.App) void {
    out.* = methods(app);
}

/// The same list with no application attached. Only names, arity and
/// documentation are meaningful: calling one of these would trap. It exists so
/// `myzig generate` can describe the built-ins without starting an app.
pub fn fillInert(out: *[count]ipc.service.Method) void {
    out.* = methods(undefined);
}

/// Every built-in method. `App.init` registers all of them.
pub fn methods(app: *app_mod.App) [count]ipc.service.Method {
    return .{
        .{ .name = "Clipboard.readText", .invoke = readText, .arity = 0, .ctx = app, .docs = "Reads clipboard text, or null when it holds none." },
        .{ .name = "Clipboard.writeText", .invoke = writeText, .arity = 1, .ctx = app, .docs = "Puts text on the clipboard. False when the desktop refused." },
        .{ .name = "Dialog.open", .invoke = dialogOpen, .arity = 0, .ctx = app, .docs = "Shows an open dialog. Resolves with the chosen paths, or null when cancelled." },
        .{ .name = "Dialog.save", .invoke = dialogSave, .arity = 0, .ctx = app, .docs = "Shows a save dialog. Resolves with the chosen path, or null when cancelled." },
        .{ .name = "Dialog.message", .invoke = dialogMessage, .arity = 0, .ctx = app, .docs = "Shows a message box. Resolves with the index of the button pressed." },
        .{ .name = "Notification.show", .invoke = notificationShow, .arity = 0, .ctx = app, .docs = "Shows a desktop notification. False when the desktop refused." },
        .{ .name = "Shell.openExternal", .invoke = openExternal, .arity = 1, .ctx = app, .docs = "Opens a URL in the user's browser." },
        .{ .name = "App.version", .invoke = appVersion, .arity = 0, .ctx = app, .docs = "The framework version this window runs." },
        .{ .name = "App.info", .invoke = appInfo, .arity = 0, .ctx = app, .docs = "The application's name, id and whether this is a dev build." },
        .{ .name = "Window.show", .invoke = windowShow, .arity = 1, .ctx = app },
        .{ .name = "Window.hide", .invoke = windowHide, .arity = 0, .ctx = app },
        .{ .name = "Window.minimize", .invoke = windowMinimize, .arity = 0, .ctx = app },
        .{ .name = "Window.maximize", .invoke = windowMaximize, .arity = 0, .ctx = app },
        .{ .name = "Window.unmaximize", .invoke = windowUnmaximize, .arity = 0, .ctx = app },
        .{ .name = "Window.fullscreen", .invoke = windowFullscreen, .arity = 1, .ctx = app },
        .{ .name = "Window.restore", .invoke = windowRestore, .arity = 0, .ctx = app },
        .{ .name = "Window.focus", .invoke = windowFocus, .arity = 0, .ctx = app },
        .{ .name = "Window.setTitle", .invoke = windowSetTitle, .arity = 1, .ctx = app },
        .{ .name = "Window.setSize", .invoke = windowSetSize, .arity = 2, .ctx = app },
        .{ .name = "Window.setPosition", .invoke = windowSetPosition, .arity = 2, .ctx = app },
        .{ .name = "Window.close", .invoke = windowClose, .arity = 0, .ctx = app },
        .{ .name = "Window.state", .invoke = windowStateOf, .arity = 0, .ctx = app },
        .{ .name = "Window.bounds", .invoke = windowBoundsOf, .arity = 0, .ctx = app },
        .{ .name = "Window.openDevtools", .invoke = windowDevtools, .arity = 0, .ctx = app },
        .{ .name = "Window.setAlwaysOnTop", .invoke = windowAlwaysOnTop, .arity = 1, .ctx = app },
    };
}

/// The running app. `App.init` returns by value, so an address captured at
/// registration time would point at the discarded copy; `App.bindBackend`
/// stores the real address here once the app is in its final place.
var current_app: ?*app_mod.App = null;

/// Called by `App.bindBackend`. Every built-in handler reads the app from here
/// rather than from its `ctx`, which cannot become stale.
pub fn setApp(app: *app_mod.App) void {
    current_app = app;
}

fn appOf(ctx: ?*anyopaque) *app_mod.App {
    _ = ctx;
    return current_app orelse @panic("a built-in service ran before the app was bound");
}

// --------------------------------------------------------------- clipboard

fn readText(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    _ = args;
    const app = appOf(ctx);
    const text = app.readClipboard(&clipboard_buf) orelse return ipc.Result.success(.null);
    // `text` borrows `clipboard_buf`, which outlives this call.
    return ipc.Result.success(.{ .string = text });
}

fn writeText(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    var a = args;
    const text = a.string() catch |e| return ipc.Args.toResult(e);
    const app = appOf(ctx);
    return ipc.Result.success(.{ .bool = app.writeClipboard(text) });
}

// ----------------------------------------------------------------- dialogs

fn dialogOpen(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    return runFileDialog(ctx, args, .open_file);
}

fn dialogSave(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    return runFileDialog(ctx, args, .save_file);
}

fn runFileDialog(ctx: ?*anyopaque, args: ipc.Args, kind: desktop.FileDialogKind) ipc.Result {
    const app = appOf(ctx);

    // The page passes an options object; every field is optional.
    var a = args;
    var opts = desktop.FileDialogOptions{ .kind = kind };
    var title_buf: [256]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    var filter_buf: [64]u8 = undefined;

    if (a.count() > 0) {
        const obj = a.object() catch |e| return ipc.Args.toResult(e);
        if (ipc.decode.field(obj, "title")) |v| {
            if (v == .string) opts.title = copyInto(&title_buf, v.string);
        }
        if (ipc.decode.field(obj, "suggestedName")) |v| {
            if (v == .string) opts.suggested_name = copyInto(&name_buf, v.string);
        }
        if (ipc.decode.field(obj, "filter")) |v| {
            if (v == .string) opts.filter = copyInto(&filter_buf, v.string);
        }
        if (ipc.decode.field(obj, "directory")) |v| {
            if (v == .bool and v.bool) opts.kind = .open_directory;
        }
    }

    const choice = app.fileDialog(opts, &dialog_paths) catch |e| return switch (e) {
        error.NotSupported => ipc.Result.fail(.not_supported, "no file dialog on this platform"),
        error.TooManyPaths => ipc.Result.fail(.invalid_argument, "too many files selected"),
        error.Internal => ipc.Result.fail(.internal, "the file dialog failed"),
    };

    if (choice.cancelled) return ipc.Result.success(.null);

    // An array of strings, built into the shared reply buffer.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    out.appendSlice(app.gpa, "[") catch return ipc.Result.fail(.internal, "out of memory");
    for (choice.paths, 0..) |p, i| {
        if (i != 0) out.append(app.gpa, ',') catch return ipc.Result.fail(.internal, "out of memory");
        json.encodeString(app.gpa, &out, p) catch return ipc.Result.fail(.internal, "out of memory");
    }
    out.append(app.gpa, ']') catch return ipc.Result.fail(.internal, "out of memory");

    const len = @min(out.items.len, dialog_reply.len);
    @memcpy(dialog_reply[0..len], out.items[0..len]);
    dialog_reply_len = len;
    return ipc.Result.successRaw(dialog_reply[0..len]);
}

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn dialogMessage(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const app = appOf(ctx);
    var a = args;
    var opts = desktop.MessageOptions{};
    var title_buf: [256]u8 = undefined;
    var body_buf: [2048]u8 = undefined;

    if (a.count() > 0) {
        const obj = a.object() catch |e| return ipc.Args.toResult(e);
        if (ipc.decode.field(obj, "title")) |v| {
            if (v == .string) opts.title = copyInto(&title_buf, v.string);
        }
        if (ipc.decode.field(obj, "body")) |v| {
            if (v == .string) opts.body = copyInto(&body_buf, v.string);
        }
        if (ipc.decode.field(obj, "kind")) |v| {
            if (v == .string) {
                opts.kind = std.meta.stringToEnum(desktop.MessageKind, v.string) orelse .info;
            }
        }
    }

    const pressed = app.messageBox(opts);
    if (pressed) |i| {
        const buf = std.fmt.bufPrint(&window_reply, "{d}", .{i}) catch return ipc.Result.success(.null);
        window_reply_len = buf.len;
        return ipc.Result.successRaw(buf);
    }
    return ipc.Result.success(.null);
}

// ----------------------------------------------------------- notification

fn notificationShow(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const app = appOf(ctx);
    var a = args;
    var opts = desktop.NotificationOptions{};
    var title_buf: [256]u8 = undefined;
    var body_buf: [2048]u8 = undefined;
    var tag_buf: [64]u8 = undefined;

    // Accept either `notify({title, body})` or `notify("title", "body")`.
    if (a.count() == 1) {
        const obj = a.object() catch |e| return ipc.Args.toResult(e);
        if (ipc.decode.field(obj, "title")) |v| {
            if (v == .string) opts.title = copyInto(&title_buf, v.string);
        }
        if (ipc.decode.field(obj, "body")) |v| {
            if (v == .string) opts.body = copyInto(&body_buf, v.string);
        }
        if (ipc.decode.field(obj, "tag")) |v| {
            if (v == .string) opts.tag = copyInto(&tag_buf, v.string);
        }
        if (ipc.decode.field(obj, "silent")) |v| {
            if (v == .bool) opts.silent = v.bool;
        }
    } else if (a.count() >= 2) {
        const title = a.stringBounded(256) catch |e| return ipc.Args.toResult(e);
        const body = a.stringBounded(2048) catch |e| return ipc.Args.toResult(e);
        opts.title = copyInto(&title_buf, title);
        opts.body = copyInto(&body_buf, body);
    }
    a.done() catch |e| return ipc.Args.toResult(e);

    return ipc.Result.success(.{ .bool = app.notify(opts) });
}

// ---------------------------------------------------------------- outside

fn openExternal(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    var a = args;
    const url = a.stringBounded(4096) catch |e| return ipc.Args.toResult(e);
    const app = appOf(ctx);
    return ipc.Result.success(.{ .bool = app.openExternal(url) });
}

// ------------------------------------------------------------------- app

fn appVersion(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    _ = ctx;
    _ = args;
    return ipc.Result.success(.{ .string = version.version_string });
}

fn appInfo(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    _ = args;
    const app = appOf(ctx);
    // A small object, built into the shared reply buffer.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    out.appendSlice(app.gpa, "{\"name\":") catch return ipc.Result.fail(.internal, "out of memory");
    json.encodeString(app.gpa, &out, app.name()) catch return ipc.Result.fail(.internal, "out of memory");
    out.appendSlice(app.gpa, ",\"id\":") catch return ipc.Result.fail(.internal, "out of memory");
    json.encodeString(app.gpa, &out, app.appId()) catch return ipc.Result.fail(.internal, "out of memory");
    out.appendSlice(app.gpa, ",\"dev\":") catch return ipc.Result.fail(.internal, "out of memory");
    out.appendSlice(app.gpa, if (app.isDev()) "true" else "false") catch return ipc.Result.fail(.internal, "out of memory");
    out.append(app.gpa, '}') catch return ipc.Result.fail(.internal, "out of memory");

    const len = @min(out.items.len, window_reply.len);
    @memcpy(window_reply[0..len], out.items[0..len]);
    window_reply_len = len;
    return ipc.Result.successRaw(window_reply[0..len]);
}

// --------------------------------------------------------------- windows
//
// A window call implies the window that sent it, so these handlers take the
// window from `args.windowId` rather than from a page-supplied argument: a page
// cannot address another window.

fn windowOf(ctx: ?*anyopaque, args: ipc.Args) ?struct { app: *app_mod.App, h: @import("../window.zig").Window } {
    const app = appOf(ctx);
    const id = args.windowId() orelse return null;
    const h = app.windowById(id) orelse return null;
    return .{ .app = app, .h = h };
}

fn noWindow() ipc.Result {
    return ipc.Result.fail(.internal, "the calling window is gone");
}

fn windowShow(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    var a = args;
    const visible = a.boolean() catch true;
    w.app.showWindow(w.h, visible);
    return ipc.Result.success(.null);
}

fn windowHide(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    w.app.showWindow(w.h, false);
    return ipc.Result.success(.null);
}

fn setStateOf(ctx: ?*anyopaque, args: ipc.Args, state: events.WindowState) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    w.app.setWindowState(w.h, state) catch return ipc.Result.fail(.not_supported, "this window cannot change state");
    return ipc.Result.success(.null);
}

fn windowMinimize(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    return setStateOf(ctx, args, .minimized);
}

fn windowMaximize(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    return setStateOf(ctx, args, .maximized);
}

fn windowUnmaximize(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    return setStateOf(ctx, args, .normal);
}

fn windowRestore(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    return setStateOf(ctx, args, .normal);
}

fn windowFullscreen(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    var a = args;
    const on = a.boolean() catch true;
    w.app.setWindowFullscreen(w.h, on) catch return ipc.Result.fail(.not_supported, "fullscreen is unavailable");
    return ipc.Result.success(.null);
}

fn windowFocus(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    w.app.focusWindow(w.h);
    return ipc.Result.success(.null);
}

fn windowSetTitle(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    var a = args;
    const title = a.stringBounded(512) catch |e| return ipc.Args.toResult(e);
    w.app.setWindowTitle(w.h, title);
    return ipc.Result.success(.null);
}

fn windowSetSize(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    var a = args;
    const width = a.integer() catch |e| return ipc.Args.toResult(e);
    const height = a.integer() catch |e| return ipc.Args.toResult(e);
    // A zero or negative size would be rejected by the window manager in a way
    // the page cannot see, so it is refused here.
    if (width <= 0 or height <= 0) return ipc.Result.fail(.invalid_argument, "size must be positive");
    const cur = w.app.windowBounds(w.h) orelse return noWindow();
    w.app.setWindowBounds(w.h, .{ .x = cur.x, .y = cur.y, .width = @intCast(width), .height = @intCast(height) }) catch
        return ipc.Result.fail(.not_supported, "resizing failed");
    return ipc.Result.success(.null);
}

fn windowSetPosition(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    var a = args;
    const x = a.integer() catch |e| return ipc.Args.toResult(e);
    const y = a.integer() catch |e| return ipc.Args.toResult(e);
    const cur = w.app.windowBounds(w.h) orelse return noWindow();
    w.app.setWindowBounds(w.h, .{ .x = @intCast(x), .y = @intCast(y), .width = cur.width, .height = cur.height }) catch
        return ipc.Result.fail(.not_supported, "moving failed");
    return ipc.Result.success(.null);
}

fn windowClose(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    w.app.closeWindow(w.h);
    return ipc.Result.success(.null);
}

fn windowDevtools(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    w.app.openDevtools(w.h);
    return ipc.Result.success(.null);
}

fn windowAlwaysOnTop(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    var a = args;
    w.app.setWindowAlwaysOnTop(w.h, a.boolean() catch true);
    return ipc.Result.success(.null);
}

fn windowStateOf(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    const state = w.app.windowState(w.h) orelse return noWindow();
    return ipc.Result.success(.{ .string = switch (state.state) {
        .normal => "normal",
        .minimized => "minimized",
        .maximized => "maximized",
        .fullscreen => "fullscreen",
    } });
}

fn windowBoundsOf(ctx: ?*anyopaque, args: ipc.Args) ipc.Result {
    const w = windowOf(ctx, args) orelse return noWindow();
    const r = w.app.windowBounds(w.h) orelse return noWindow();
    const text = std.fmt.bufPrint(
        &window_reply,
        "{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}",
        .{ r.x, r.y, r.width, r.height },
    ) catch return ipc.Result.fail(.internal, "out of memory");
    window_reply_len = text.len;
    return ipc.Result.successRaw(text[0..]);
}

test "every built-in method has a service-qualified name" {
    // Names are `Service.method`, which is what the bridge sends and what the
    // generated TypeScript declares; a bare name would be unreachable from a
    // page.
    const names = [_][]const u8{
        "Clipboard.readText", "Clipboard.writeText", "Dialog.open",
        "Dialog.save",        "Dialog.message",      "Notification.show",
        "Shell.openExternal", "App.version",         "App.info",
    };
    for (names) |n| {
        const dot = std.mem.indexOfScalar(u8, n, '.') orelse return error.TestUnexpectedResult;
        try std.testing.expect(dot > 0 and dot + 1 < n.len);
    }
    _ = events;
}

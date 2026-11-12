//! The macos backend.
//!
//! Not implemented yet: see docs/FEATURE_PARITY.md. Every operation returns
//! `error.NotSupported` rather than silently doing nothing, so an app built
//! for macos today fails loudly at startup instead of misbehaving.

const std = @import("std");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");

pub const BackendImpl = struct {};

fn init(ctx: *anyopaque, app: *app_mod.App) errors.InitError!void {
    _ = ctx;
    _ = app;
    return errors.InitError.PlatformUnavailable;
}
fn deinit(ctx: *anyopaque) void {
    _ = ctx;
}
fn run(ctx: *anyopaque) errors.InitError!void {
    _ = ctx;
    return errors.InitError.PlatformUnavailable;
}
fn quit(ctx: *anyopaque) void {
    _ = ctx;
}
fn createWindow(ctx: *anyopaque, id: u32, opts: backend.WindowOptions) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = opts;
    return errors.WindowError.NotSupported;
}
fn destroyWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}
fn showWindow(ctx: *anyopaque, id: u32, v: bool) void {
    _ = ctx;
    _ = id;
    _ = v;
}
fn focusWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}
fn setBounds(ctx: *anyopaque, id: u32, r: backend.Rect) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = r;
    return errors.WindowError.NotSupported;
}
fn getBounds(ctx: *anyopaque, id: u32) ?backend.Rect {
    _ = ctx;
    _ = id;
    return null;
}
fn setTitle(ctx: *anyopaque, id: u32, t: []const u8) void {
    _ = ctx;
    _ = id;
    _ = t;
}
fn setState(ctx: *anyopaque, id: u32, s: events.WindowState) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = s;
    return errors.WindowError.NotSupported;
}
fn setAlwaysOnTop(ctx: *anyopaque, id: u32, on: bool) void {
    _ = ctx;
    _ = id;
    _ = on;
}
fn setFullscreen(ctx: *anyopaque, id: u32, on: bool) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = on;
    return errors.WindowError.NotSupported;
}
fn loadUrl(ctx: *anyopaque, id: u32, u: []const u8) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = u;
    return errors.WindowError.NotSupported;
}
fn evalJs(ctx: *anyopaque, id: u32, c: []const u8) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = c;
    return errors.WindowError.NotSupported;
}
fn injectScript(ctx: *anyopaque, id: u32, c: []const u8) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = c;
    return errors.WindowError.NotSupported;
}
fn openDevtools(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}
fn monitors(ctx: *anyopaque, out: []backend.MonitorInfo) usize {
    _ = ctx;
    _ = out;
    return 0;
}
fn systemTheme(ctx: *anyopaque) events.Theme {
    _ = ctx;
    return .light;
}
fn wake(ctx: *anyopaque) void {
    _ = ctx;
}
fn requestFrame(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
}
fn present(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
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
        .monitors = monitors,
        .system_theme = systemTheme,
        .wake = wake,
        .request_frame = requestFrame,
        .present = present,
    };
}

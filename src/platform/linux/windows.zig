//! GTK window management. Implemented in the next step.
const std = @import("std");
const backend = @import("../backend.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");

pub const CreateError = error{ OutOfMemory, InvalidArgument, NotSupported };

pub fn create(app: *app_mod.App, opts: backend.WindowOptions) CreateError!void { _ = app; _ = opts; return error.NotSupported; }
pub fn destroy(id: u32) void { _ = id; }
pub fn show(id: u32, visible: bool) void { _ = id; _ = visible; }
pub fn focus(id: u32) void { _ = id; }
pub fn setBounds(id: u32, r: backend.Rect) bool { _ = id; _ = r; return false; }
pub fn getBounds(id: u32) ?backend.Rect { _ = id; return null; }
pub fn setTitle(id: u32, title: []const u8) void { _ = id; _ = title; }
pub fn setState(id: u32, state: events.WindowState) bool { _ = id; _ = state; return false; }
pub fn setAlwaysOnTop(id: u32, on: bool) void { _ = id; _ = on; }
pub fn setFullscreen(id: u32, on: bool) bool { _ = id; _ = on; return false; }
pub fn monitors(out: []backend.MonitorInfo) usize { _ = out; return 0; }
pub fn systemTheme() events.Theme { return .light; }
pub fn requestFrame(id: u32) void { _ = id; }
pub fn present(id: u32) void { _ = id; }
pub fn shutdownAll() void {}

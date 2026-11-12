//! The main-thread dispatch integration for GTK.
const std = @import("std");
const app_mod = @import("../../app.zig");

pub fn install(app: *app_mod.App) u32 { _ = app; return 0; }
pub fn wake() void {}

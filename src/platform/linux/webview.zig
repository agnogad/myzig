//! WebKitGTK web views. Implemented in the next step.
pub fn loadUrl(id: u32, url: []const u8) bool { _ = id; _ = url; return false; }
pub fn eval(id: u32, code: []const u8) bool { _ = id; _ = code; return false; }
pub fn inject(id: u32, code: []const u8) bool { _ = id; _ = code; return false; }
pub fn openDevtools(id: u32) void { _ = id; }
pub fn shutdownAll() void {}

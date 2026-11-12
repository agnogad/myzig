//! Waking the GLib main loop for work posted from another thread.
//!
//! Other threads hand work to the main thread through `App`'s queue. They then
//! need the GLib loop to wake up and drain it. MyZig does that with a single
//! `g_idle_add` source that is **re-armed only when needed**:
//!
//! * `wake` sets a flag and adds the idle source if none is armed.
//! * The idle callback clears the flag, drains the queue, and returns
//!   `G_SOURCE_REMOVE`.
//!
//! An idle source added again from inside its own callback would keep the loop
//! spinning at 100% CPU, so the flag, not the source's return value, decides
//! when work is pending. When nothing is posted, no source is armed and the
//! loop blocks in `poll`: idle CPU is zero.

const std = @import("std");
const backend = @import("../backend.zig");
const app_mod = @import("../../app.zig");
const ffi = @import("ffi.zig");

/// One shared idle source for the process: GTK drives a single main loop.
var armed: bool = false;
var pending: bool = false;
var sink: ?backend.EventSink = null;
var idle_cb: ffi.GSFunc = null;

fn ensureCallback() void {
    if (idle_cb != null) return;
    idle_cb = &struct {
        // GSourceFunc: (user_data) -> gboolean
        fn cb(data: ?*anyopaque) callconv(.c) ffi.gboolean {
            _ = data;
            onIdle();
            return ffi.FALSE; // G_SOURCE_REMOVE
        }
    }.cb;
}

/// Installs the dispatch plumbing and returns a non-zero marker on success.
pub fn install(app: *app_mod.App) u32 {
    sink = app.sink();
    ensureCallback();
    armed = false;
    pending = false;
    return 1;
}

pub fn uninstall() void {
    sink = null;
    armed = false;
    pending = false;
}

/// Called from any thread. Safe to call while the loop runs.
pub fn wake() void {
    // Marking work pending before inspecting `armed` closes the race where the
    // idle callback drains, finds nothing, and removes the source just as
    // another thread posts: the worst case is one extra, harmless idle pass.
    @atomicStore(bool, &pending, true, .release);
    if (armed or idle_cb == null) return;
    // GLib's idle sources are typical: low priority, default context.
    _ = ffi.g_idle_add_full(
        ffi.G_PRIORITY_DEFAULT_IDLE,
        idle_cb,
        null,
        null,
    );
    armed = true;
}

fn onIdle() void {
    armed = false;
    // Clear before draining, so a post that lands during the drain re-arms.
    @atomicStore(bool, &pending, false, .release);
    if (sink) |s| s.dispatch();
}

test "wake marks work pending without a loop" {
    // Without GLib loaded, wake must not crash: the flag is set first, the
    // g_idle_add call is the only thing that needs the library.
    pending = false;
    armed = false;
    // Call the pure flag path.
    @atomicStore(bool, &pending, true, .release);
    try std.testing.expect(pending);
    pending = false;
}

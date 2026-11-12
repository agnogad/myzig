//! Platform abstraction.
pub const backend = @import("backend.zig");
pub const Backend = backend.Backend;
pub const current = backend.current;

/// The rectangle a native surface is drawn into, in device-independent pixels.
pub const DrawRect = backend.DrawRect;

/// A native drawing callback.
pub const NativeDraw = backend.NativeDraw;

/// Desktop integration types, re-exported so an application can name them
/// without reaching into `desktop`.
pub const desktop = @import("desktop.zig");

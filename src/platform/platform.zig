//! Platform abstraction.
pub const backend = @import("backend.zig");
pub const Backend = backend.Backend;
pub const current = backend.current;

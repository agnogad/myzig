//! Error sets and shared error helpers.
//!
//! MyZig prefers explicit, small error sets over `anyerror`, so a call site
//! shows what can actually go wrong. Errors that cross the platform boundary
//! are narrowed to the sets declared here.

const std = @import("std");

/// Errors any application can meet while starting up.
pub const InitError = error{
    /// The native toolkit is unavailable (no display, missing library).
    PlatformUnavailable,
    /// The display server could not be reached.
    NoDisplay,
    /// A required shared library could not be loaded.
    LibraryMissing,
    /// A required native symbol was not found in a library.
    SymbolMissing,
    /// Out of memory.
    OutOfMemory,
    /// The application is already running and single-instance mode is on.
    AlreadyRunning,
};

/// Errors from window operations.
pub const WindowError = error{
    /// No window exists for the handle (destroyed, or never created).
    InvalidWindow,
    /// The window manager or the backend refused the request.
    NotSupported,
    /// A size or position was out of range.
    InvalidArgument,
    OutOfMemory,
};

/// Errors from the IPC layer.
pub const IpcError = error{
    /// No handler is registered for the requested method.
    MethodNotFound,
    /// The arguments did not match the handler's signature.
    InvalidArguments,
    /// The handler returned an error.
    HandlerFailed,
    /// The request was cancelled by the page or the window closing.
    Cancelled,
    /// The message exceeded the size limit.
    MessageTooLarge,
    /// The message prefix (per-window secret) did not match.
    Untrusted,
    /// A payload could not be encoded or decoded.
    SerializationFailed,
    OutOfMemory,
};

/// Errors from the desktop API surface.
pub const DesktopError = error{
    NotSupported,
    /// The user dismissed the dialog.
    Cancelled,
    /// A permission or entitlement is missing.
    Denied,
    InvalidArgument,
    OutOfMemory,
};

/// A feature is compiled in but not implemented on this platform yet.
///
/// Returning this instead of silently doing nothing is a hard rule: see
/// docs/platforms.md.
pub const unsupported = error.NotSupported;

/// Formats an error for logging without pulling in formatting bloat.
pub fn name(err: anyerror) []const u8 {
    return @errorName(err);
}

test "error names are stable" {
    try std.testing.expectEqualStrings("OutOfMemory", name(error.OutOfMemory));
    try std.testing.expectEqualStrings("NotSupported", name(unsupported));
}

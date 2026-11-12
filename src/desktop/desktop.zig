//! Desktop integration: clipboard, file dialogs, message boxes, notifications,
//! opening URLs and revealing files.
//!
//! Every entry point here has a matching method on `App`, which is the way an
//! application should reach them:
//!
//! ```zig
//! _ = app.openExternal("https://example.com");
//! ```
//!
//! This module is public so that the types can be named — an application needs
//! `FileDialogOptions` to call `app.fileDialog` — and so that a test can build
//! a `Desktop` over its own vtable.

pub const platform = @import("../platform/desktop.zig");

pub const Desktop = platform.Desktop;
pub const Theme = platform.Theme;

pub const FileChoice = platform.FileChoice;
pub const FileDialogKind = platform.FileDialogKind;
pub const FileDialogOptions = platform.FileDialogOptions;
pub const FileDialogError = platform.FileDialogError;

pub const MessageKind = platform.MessageKind;
pub const MessageOptions = platform.MessageOptions;

pub const NotificationOptions = platform.NotificationOptions;

pub const PathBuffer = platform.PathBuffer;

test {
    @import("std").testing.refAllDecls(@This());
}

//! Desktop integrations: clipboard, dialogs, notifications, system theme and
//! opening things outside the app.
//!
//! ## Why these are separate from windows
//!
//! A window is a long-lived object the framework tracks. A clipboard read, a
//! file dialog or a notification is a **one-shot request with a reply**, so it
//! does not belong in the window registry and must work with no window open.
//!
//! ## Threading
//!
//! Every call here happens on the main thread. A modal file dialog blocks until
//! the user answers, which is what the page's `await` expects; a notification
//! does not block.

const std = @import("std");

/// The result of a file dialog.
pub const FileChoice = struct {
    /// Absolute paths the user chose. Empty when they cancelled.
    paths: []const []const u8,
    /// True when the dialog was dismissed rather than answered.
    cancelled: bool = false,
};

/// Which file-dialog behaviour the caller wants.
pub const FileDialogKind = enum {
    open_file,
    open_files,
    open_directory,
    save_file,
};

/// Options for a file dialog. Fully defaulted.
pub const FileDialogOptions = struct {
    kind: FileDialogKind = .open_file,
    /// Dialog title.
    title: []const u8 = "",
    /// Suggested file name for a save dialog.
    suggested_name: []const u8 = "",
    /// Directory the dialog starts in, or empty for the platform default.
    start_in: []const u8 = "",
    /// Glob-ish filter, e.g. `"*.png"`. Empty shows every file.
    filter: []const u8 = "",
};

/// A button in a message box.
pub const MessageKind = enum {
    info,
    warning,
    question,
    @"error",
};

/// Options for a message box.
pub const MessageOptions = struct {
    kind: MessageKind = .info,
    /// First line, shown in bold.
    title: []const u8 = "",
    /// Body text.
    body: []const u8 = "",
    /// Buttons, in display order. Empty means a single "OK".
    buttons: []const []const u8 = &.{},
};

/// A notification to show.
pub const NotificationOptions = struct {
    title: []const u8 = "",
    body: []const u8 = "",
    /// Replaces a notification with the same tag already on screen instead of
    /// stacking a second one.
    tag: []const u8 = "",
    /// Suppress the notification sound.
    silent: bool = false,
};

/// What a backend must provide. A platform that cannot implement one of these
/// returns `error.NotSupported`: a silently ignored notification is worse than
/// a stated limitation.
pub const Desktop = struct {
    ctx: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Clipboard text, written into `buf`. The returned slice borrows `buf`.
        read_clipboard: *const fn (ctx: ?*anyopaque, buf: []u8) ?[]const u8,
        write_clipboard: *const fn (ctx: ?*anyopaque, text: []const u8) bool,

        /// Shows a file dialog. `out` receives the chosen paths, which borrow
        /// its storage; the caller frees nothing.
        file_dialog: *const fn (
            ctx: ?*anyopaque,
            opts: FileDialogOptions,
            out: *const PathBuffer,
        ) FileDialogError!FileChoice,

        /// Shows a message box and returns the index of the button pressed, or
        /// null when it was dismissed.
        message_box: *const fn (ctx: ?*anyopaque, opts: MessageOptions) ?usize,

        /// Shows a notification. Returns false when the platform refused it.
        notify: *const fn (ctx: ?*anyopaque, opts: NotificationOptions) bool,

        /// Opens a URL in the user's browser.
        open_external: *const fn (ctx: ?*anyopaque, url: []const u8) bool,

        /// Reveals a file in the user's file manager.
        show_in_folder: *const fn (ctx: ?*anyopaque, path: []const u8) bool,

        /// The desktop's light/dark preference.
        theme: *const fn (ctx: ?*anyopaque) Theme,
    };

    pub fn readClipboard(self: Desktop, buf: []u8) ?[]const u8 {
        return self.vtable.read_clipboard(self.ctx, buf);
    }

    pub fn writeClipboard(self: Desktop, text: []const u8) bool {
        return self.vtable.write_clipboard(self.ctx, text);
    }

    pub fn fileDialog(self: Desktop, opts: FileDialogOptions, out: *const PathBuffer) FileDialogError!FileChoice {
        return self.vtable.file_dialog(self.ctx, opts, out);
    }

    pub fn messageBox(self: Desktop, opts: MessageOptions) ?usize {
        return self.vtable.message_box(self.ctx, opts);
    }

    pub fn notify(self: Desktop, opts: NotificationOptions) bool {
        return self.vtable.notify(self.ctx, opts);
    }

    pub fn openExternal(self: Desktop, url: []const u8) bool {
        return self.vtable.open_external(self.ctx, url);
    }

    pub fn showInFolder(self: Desktop, path: []const u8) bool {
        return self.vtable.show_in_folder(self.ctx, path);
    }

    /// The desktop's light/dark preference as its own method, so it does not
    /// collide with the `theme` vtable field.
    pub fn currentTheme(self: Desktop) Theme {
        return self.vtable.theme(self.ctx);
    }
};

pub const FileDialogError = error{
    NotSupported,
    TooManyPaths,
    Internal,
};

pub const Theme = enum { light, dark };

/// Storage for the paths a dialog returns. A fixed capacity keeps the dialog
/// allocation-free and bounds a runaway selection.
pub const PathBuffer = struct {
    storage: [64][std.fs.max_path_bytes]u8 = undefined,
    count: usize = 0,

    pub fn append(self: *PathBuffer, path: []const u8) FileDialogError![]const u8 {
        if (self.count >= self.storage.len) return error.TooManyPaths;
        if (path.len > self.storage[self.count].len) return error.TooManyPaths;
        @memcpy(self.storage[self.count][0..path.len], path);
        self.count += 1;
        return self.storage[self.count - 1][0..path.len];
    }

    pub fn slice(self: *const PathBuffer, items: []const []const u8) []const []const u8 {
        return items[0..self.count];
    }
};

/// A read of the clipboard with its own buffer, so the common case needs no
/// allocation by the caller.
pub const ClipboardBuffer = struct {
    storage: [1 << 16]u8 = undefined,

    pub fn slice(self: *const ClipboardBuffer, len: usize) []const u8 {
        return self.storage[0..len];
    }
};

test "path buffer bounds its capacity" {
    var pb = PathBuffer{};
    _ = try pb.append("/tmp/a");
    _ = try pb.append("/tmp/b");
    try std.testing.expectEqual(@as(usize, 2), pb.count);
    try std.testing.expectEqualStrings("/tmp/a", pb.storage[0][0..6]);
}

test "path buffer rejects a path that does not fit" {
    var pb = PathBuffer{};
    // One byte longer than the entry can hold.
    var huge: [std.fs.max_path_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.TooManyPaths, pb.append(&huge));
}

test "path buffer stays bounded when full" {
    var pb = PathBuffer{};
    var i: usize = 0;
    while (i < pb.storage.len) : (i += 1) {
        _ = try pb.append("/tmp/x");
    }
    try std.testing.expectError(error.TooManyPaths, pb.append("/tmp/overflow"));
}

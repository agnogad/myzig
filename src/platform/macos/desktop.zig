//! The desktop APIs on macOS: clipboard, dialogs, notifications, opening
//! things outside the app, and the light/dark preference.
//!
//! ## What each one is
//!
//! | call | AppKit / Foundation |
//! |------|---------------------|
//! | clipboard | `NSPasteboard.generalPasteboard` |
//! | file dialog | `NSOpenPanel` / `NSSavePanel` |
//! | message box | `NSAlert` |
//! | notification | `NSUserNotificationCenter` (deprecated) or `UNUserNotificationCenter` |
//! | open a URL | `NSWorkspace.openURL:` |
//! | reveal a file | `NSWorkspace.selectFile:inFileViewerRootedAtPath:` |
//! | light/dark | `NSRunningApplication` / `NSApplication.effectiveAppearance` |
//!
//! ## Honest gaps
//!
//! Every method here answers truthfully. Where AppKit cannot do what the
//! contract asks without something this backend does not have — a running run
//! loop, a bundle identifier for notifications — the call returns `false` or
//! `error.NotSupported` rather than pretending. A notification that silently
//! does not appear is worse than one that reports it could not.
//!
//! ## Testing
//!
//! Written against Apple's documented API and **never run**: there is no Mac
//! here. The parts with pure logic — the modal-response mapping and the
//! filter translation — are separated out and tested on Linux.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const desktop = @import("../desktop.zig");

pub fn vtable() desktop.Desktop.VTable {
    return .{
        .read_clipboard = readClipboard,
        .write_clipboard = writeClipboard,
        .file_dialog = fileDialog,
        .message_box = messageBox,
        .notify = notify,
        .open_external = openExternal,
        .show_in_folder = showInFolder,
        .theme = theme,
    };
}

/// An `NSString` from a Zig slice, or null. The caller releases it.
fn nsString(text: []const u8) objc.ObjCId {
    const cls = objc.class("NSString") orelse return null;
    const buf = std.heap.c_allocator.alloc(u8, text.len + 1) catch return null;
    defer std.heap.c_allocator.free(buf);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return objc.sendIdCStr(cls, "stringWithUTF8String:", @ptrCast(buf.ptr));
}

/// Copies an `NSString` into `buf`, or null when it does not fit.
///
/// The length is taken first so a value larger than the buffer is refused
/// whole rather than truncated: half a pasteboard is not the text the user
/// copied.
fn copyString(s: objc.ObjCId, buf: []u8) ?[]const u8 {
    const utf8 = objc.sendGetId(s, "UTF8String") orelse return null;
    const p: [*:0]const u8 = @ptrCast(utf8);
    const text = std.mem.span(p);
    if (text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

// --------------------------------------------------------------- clipboard

fn readClipboard(_: ?*anyopaque, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const pb_class = objc.class("NSPasteboard") orelse return null;
    const pb = objc.sendId1(pb_class, "generalPasteboard", null) orelse return null;

    // `stringForType:` is the one-call form; NSPasteboardTypeString is `public.utf8-plain-text`.
    const pb_type = nsString("public.utf8-plain-text") orelse return null;
    defer objc.sendVoid(pb_type, "release");
    const s = objc.sendId1(pb, "stringForType:", pb_type) orelse return null;
    return copyString(s, buf);
}

fn writeClipboard(_: ?*anyopaque, text: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const pb_class = objc.class("NSPasteboard") orelse return false;
    const pb = objc.sendId1(pb_class, "generalPasteboard", null) orelse return false;

    // A write replaces what was there; `clearContents` is what makes it the
    // only item on the pasteboard rather than an addition.
    _ = objc.sendGetI64(pb, "clearContents");

    const s = nsString(text) orelse return false;
    defer objc.sendVoid(s, "release");
    const pb_type = nsString("public.utf8-plain-text") orelse return false;
    defer objc.sendVoid(pb_type, "release");

    // `setString:forType:` answers BOOL.
    return objc.sendId2Bool(pb, "setString:forType:", s, pb_type);
}

// ------------------------------------------------------------- file dialog

/// The modal response AppKit uses for "the user pressed the default button".
pub const ns_modal_response_ok: i64 = 1;

/// Whether a modal response means the user chose something.
///
/// `NSModalResponseOK` is 1 and cancel is 0, and the panel's `runModal` returns
/// one of the two. Written out because a swapped comparison would silently
/// treat a cancel as a choice.
pub fn isConfirmed(response: i64) bool {
    return response == ns_modal_response_ok;
}

/// The `allowedFileTypes` entry for a dialog filter, or null for no filter.
///
/// The contract's filter is glob-ish (`"*.png"`), while `NSOpenPanel` wants
/// extensions (`"png"`). A filter that is not of that shape is refused rather
/// than passed through, because AppKit would show an empty file list.
pub fn extensionFor(filter: []const u8) ?[]const u8 {
    if (filter.len == 0) return null;
    if (std.mem.startsWith(u8, filter, "*.")) {
        const ext = filter[2..];
        if (ext.len == 0) return null;
        // A wildcard *inside* the extension is not something AppKit can match:
        // `allowedFileTypes` are literal extensions. Passing `p*g` through
        // would give an empty file list with no explanation.
        if (std.mem.indexOfScalar(u8, ext, '*') != null) return null;
        return ext;
    }
    // A bare extension is already what AppKit wants.
    if (std.mem.indexOfScalar(u8, filter, '.') == null and std.mem.indexOfScalar(u8, filter, '*') == null) {
        return filter;
    }
    return null;
}

fn fileDialog(_: ?*anyopaque, opts: desktop.FileDialogOptions, out: *const desktop.PathBuffer) desktop.FileDialogError!desktop.FileChoice {
    if (comptime builtin.os.tag != .macos) return error.NotSupported;
    var pb = @constCast(out);

    const panel_class = switch (opts.kind) {
        .save_file => objc.class("NSSavePanel"),
        else => objc.class("NSOpenPanel"),
    } orelse return error.NotSupported;

    const panel = objc.sendId1(panel_class, "alloc", null) orelse return error.NotSupported;
    const shown = objc.sendId1(panel, "init", null) orelse {
        objc.sendVoid(panel, "release");
        return error.NotSupported;
    };
    defer objc.sendVoid(shown, "release");

    // Only the open panel distinguishes files from directories.
    if (opts.kind != .save_file) {
        objc.sendBool(shown, "setCanChooseFiles:", opts.kind != .open_directory);
        objc.sendBool(shown, "setCanChooseDirectories:", opts.kind == .open_directory);
        objc.sendBool(shown, "setAllowsMultipleSelection:", opts.kind == .open_files);
    }

    if (opts.title.len > 0) {
        if (nsString(opts.title)) |s| {
            objc.sendVoidId(shown, "setMessage:", s);
            objc.sendVoid(s, "release");
        }
    }
    if (opts.kind == .save_file and opts.suggested_name.len > 0) {
        if (nsString(opts.suggested_name)) |s| {
            objc.sendVoidId(shown, "setNameFieldStringValue:", s);
            objc.sendVoid(s, "release");
        }
    }
    if (opts.start_in.len > 0) {
        // `setDirectoryURL:` takes an NSURL, not a path string.
        if (nsString(opts.start_in)) |path| {
            if (objc.class("NSURL")) |url_class| {
                if (objc.sendId1(url_class, "fileURLWithPath:", path)) |url| {
                    objc.sendVoidId(shown, "setDirectoryURL:", url);
                }
            }
            objc.sendVoid(path, "release");
        }
    }
    if (extensionFor(opts.filter)) |ext| {
        if (nsString(ext)) |s| {
            const arr_class = objc.class("NSArray") orelse null;
            if (arr_class) |ac| {
                if (objc.sendId1(ac, "arrayWithObject:", s)) |arr| {
                    objc.sendVoidId(shown, "setAllowedFileTypes:", arr);
                }
            }
            objc.sendVoid(s, "release");
        }
    }

    const response = objc.sendGetI64(shown, "runModal");
    if (!isConfirmed(response)) return .{ .paths = &.{}, .cancelled = true };

    var chosen: [64][]const u8 = undefined;
    var n: usize = 0;

    if (opts.kind == .save_file) {
        if (objc.sendGetId(shown, "URL")) |url| {
            if (urlPath(url)) |path| {
                if (n < chosen.len) {
                    chosen[n] = pb.append(path) catch return error.TooManyPaths;
                    n += 1;
                }
            }
        }
    } else {
        if (objc.sendGetId(shown, "URLs")) |urls| {
            const count = objc.sendGetI64(urls, "count");
            var i: i64 = 0;
            while (i < count and n < chosen.len) : (i += 1) {
                if (objc.sendGetIdI64(urls, "objectAtIndex:", i)) |url| {
                    if (urlPath(url)) |path| {
                        chosen[n] = pb.append(path) catch return error.TooManyPaths;
                        n += 1;
                    }
                }
            }
        }
    }

    if (n == 0) return .{ .paths = &.{}, .cancelled = true };
    return .{ .paths = chosen[0..n], .cancelled = false };
}

/// The filesystem path of a file `NSURL`, or null.
fn urlPath(url: objc.ObjCId) ?[]const u8 {
    const p = objc.sendGetId(url, "path") orelse return null;
    const cstr = objc.cString(p) orelse return null;
    return std.mem.span(cstr);
}

// ------------------------------------------------------------- message box

fn messageBox(_: ?*anyopaque, opts: desktop.MessageOptions) ?usize {
    if (comptime builtin.os.tag != .macos) return null;
    const alert_class = objc.class("NSAlert") orelse return null;
    const alert = objc.sendId1(alert_class, "alloc", null) orelse return null;
    const shown = objc.sendId1(alert, "init", null) orelse {
        objc.sendVoid(alert, "release");
        return null;
    };
    defer objc.sendVoid(shown, "release");

    if (opts.title.len > 0) {
        if (nsString(opts.title)) |s| {
            objc.sendVoidId(shown, "setMessageText:", s);
            objc.sendVoid(s, "release");
        }
    }
    if (opts.body.len > 0) {
        if (nsString(opts.body)) |s| {
            objc.sendVoidId(shown, "setInformativeText:", s);
            objc.sendVoid(s, "release");
        }
    }

    // `NSAlertStyle`: 0 warning, 1 informational, 2 critical. A question has no
    // style of its own, so it is shown as informational.
    const style: i64 = switch (opts.kind) {
        .warning => 0,
        .@"error" => 2,
        else => 1,
    };
    objc.sendI64(shown, "setAlertStyle:", style);

    if (opts.buttons.len == 0) {
        _ = objc.sendId1(shown, "addButtonWithTitle:", nsString("OK"));
    } else {
        for (opts.buttons) |label| {
            const s = nsString(label) orelse continue;
            _ = objc.sendId1(shown, "addButtonWithTitle:", s);
            objc.sendVoid(s, "release");
        }
    }

    // `runModal` returns `NSAlertFirstButtonReturn` (1000) for the first button
    // and 1001, 1002… for the rest, not 0, 1, 2.
    const raw = objc.sendGetI64(shown, "runModal");
    return buttonIndex(raw);
}

/// The index of the button an `NSAlert` reported, or null when dismissed.
///
/// The first button is 1000, not 0 — a subtraction that is easy to omit and
/// then every answer looks like the first button.
pub fn buttonIndex(response: i64) ?usize {
    if (response < 1000) return null;
    return @intCast(response - 1000);
}

// ------------------------------------------------------------- notification

fn notify(_: ?*anyopaque, opts: desktop.NotificationOptions) bool {
    _ = opts;
    if (comptime builtin.os.tag != .macos) return false;
    // `NSUserNotificationCenter` needs a bundle identifier and is deprecated;
    // `UNUserNotificationCenter` needs the same plus a user authorization
    // prompt this backend has no way to show or await. Rather than post
    // something macOS will silently drop, this says it cannot.
    return false;
}

// ------------------------------------------------------------- outside the app

fn openExternal(_: ?*anyopaque, url: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const ws_class = objc.class("NSWorkspace") orelse return false;
    const ws = objc.sendId1(ws_class, "sharedWorkspace", null) orelse return false;

    // `openURL:` is deprecated in favour of `openURL:configuration:completionHandler:`,
    // which takes a block; the one-argument form still works and needs none.
    const u = nsString(url) orelse return false;
    defer objc.sendVoid(u, "release");
    if (objc.class("NSURL")) |url_class| {
        if (objc.sendId1(url_class, "URLWithString:", u)) |ns_url| {
            return objc.sendId1Bool(ws, "openURL:", ns_url);
        }
    }
    return false;
}

fn showInFolder(_: ?*anyopaque, path: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    const ws_class = objc.class("NSWorkspace") orelse return false;
    const ws = objc.sendId1(ws_class, "sharedWorkspace", null) orelse return false;

    const p = nsString(path) orelse return false;
    defer objc.sendVoid(p, "release");
    const empty = nsString("") orelse return false;
    defer objc.sendVoid(empty, "release");

    // `selectFile:inFileViewerRootedAtPath:` answers BOOL. An empty root means
    // "open the containing folder", which is what revealing means here.
    return objc.sendId2Bool(ws, "selectFile:inFileViewerRootedAtPath:", p, empty);
}

// ------------------------------------------------------------------- theme

fn theme(_: ?*anyopaque) desktop.Theme {
    if (comptime builtin.os.tag != .macos) return .light;
    const app_class = objc.class("NSApplication") orelse return .light;
    const app = objc.sendId1(app_class, "sharedApplication", null) orelse return .light;
    const appearance = objc.sendGetId(app, "effectiveAppearance") orelse return .light;

    // The name is `NSAppearanceNameAqua` or `...DarkAqua`; comparing the name
    // avoids needing the constant objects themselves.
    const name_obj = objc.sendGetId(appearance, "name") orelse return .light;
    const cstr = objc.cString(name_obj) orelse return .light;
    const name = std.mem.span(cstr);
    return themeFromAppearanceName(name);
}

/// Maps an `NSAppearance` name to the contract's two themes.
///
/// Anything that is not the Dark Aqua name is light, including the
/// high-contrast variants: they are light or dark by their base name, so the
/// substring is what is checked.
pub fn themeFromAppearanceName(name: []const u8) desktop.Theme {
    if (std.mem.indexOf(u8, name, "Dark") != null) return .dark;
    return .light;
}

// ------------------------------------------------------------------- tests

test "a cancelled panel is not a choice" {
    try std.testing.expect(!isConfirmed(0)); // NSModalResponseCancel
    try std.testing.expect(isConfirmed(1)); // NSModalResponseOK
}

test "the first alert button is 1000, not 0" {
    // Subtracting nothing would report every answer as the first button.
    try std.testing.expectEqual(@as(?usize, 0), buttonIndex(1000));
    try std.testing.expectEqual(@as(?usize, 1), buttonIndex(1001));
    try std.testing.expectEqual(@as(?usize, 2), buttonIndex(1002));
    // A dismissal is not button zero.
    try std.testing.expect(buttonIndex(0) == null);
    try std.testing.expect(buttonIndex(-1) == null);
}

test "a glob filter becomes the extension AppKit wants" {
    try std.testing.expectEqualStrings("png", extensionFor("*.png").?);
    // A bare extension is already what the panel takes.
    try std.testing.expectEqualStrings("png", extensionFor("png").?);
    // No filter means every file.
    try std.testing.expect(extensionFor("") == null);
    // Shapes AppKit cannot express are refused rather than passed through,
    // which would show an empty file list.
    try std.testing.expect(extensionFor("*") == null);
    try std.testing.expect(extensionFor("*.") == null);
    try std.testing.expect(extensionFor("*.p*g") == null);
}

test "only the dark appearance name is dark" {
    try std.testing.expectEqual(desktop.Theme.light, themeFromAppearanceName("NSAppearanceNameAqua"));
    try std.testing.expectEqual(desktop.Theme.dark, themeFromAppearanceName("NSAppearanceNameDarkAqua"));
    // The high-contrast variants carry their base name in the string.
    try std.testing.expectEqual(desktop.Theme.dark, themeFromAppearanceName("NSAppearanceNameAccessibilityHighContrastDarkAqua"));
    try std.testing.expectEqual(desktop.Theme.light, themeFromAppearanceName("NSAppearanceNameAccessibilityHighContrastAqua"));
}

test "every desktop call is answered, not silently dropped" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    // Off macOS nothing can work, and each call says so rather than pretending.
    try std.testing.expect(readClipboard(null, undefined) == null);
    try std.testing.expect(!writeClipboard(null, "text"));
    try std.testing.expect(!notify(null, .{}));
    try std.testing.expect(!openExternal(null, "https://example.invalid"));
    try std.testing.expect(!showInFolder(null, "/tmp"));
    try std.testing.expectEqual(desktop.Theme.light, theme(null));
}

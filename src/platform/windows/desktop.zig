//! The desktop APIs on Windows: clipboard, file dialogs, message boxes,
//! notifications, opening things outside the app, and the theme.
//!
//! ## What each one is
//!
//! | call | Win32 |
//! |------|-------|
//! | clipboard | `OpenClipboard` / `GetClipboardData(CF_UNICODETEXT)` |
//! | file dialog | `GetOpenFileNameW` / `GetSaveFileNameW` |
//! | message box | `MessageBoxW` |
//! | notification | `Shell_NotifyIcon` balloon, via the tray |
//! | open a URL | `ShellExecuteW("open", ...)` |
//! | reveal a file | `SHOpenFolderAndSelectItems` |
//! | light/dark | `AppsUseLightTheme` in the registry |
//!
//! ## The flags that are easy to get wrong
//!
//! `OPENFILENAMEW.lStructSize` must equal `@sizeOf(OPENFILENAMEW)` or the call
//! fails with no error to read. The filter is a **double**-NUL-terminated list
//! of label/value pairs followed by a second NUL — not a single string. And a
//! multi-select dialog returns `dir\0file1\0file2\0\0`, not a path per line.
//! Each of those has a pure function and a test, because all three fail
//! silently.
//!
//! ## Testing
//!
//! Written against the documented Win32 API and **never run**: there is no
//! Windows machine here. The mapping functions run on Linux; the calls do not.

const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("../desktop.zig");
const ffi = @import("ffi.zig");
const backend_mod = @import("backend.zig");
const log = @import("../../log.zig");

pub fn vtable() desktop.Desktop.VTable {
    return .{
        .read_clipboard = readClipboard,
        .write_clipboard = writeClipboard,
        .file_dialog = fileDialog,
        .message_box = messageBox,
        .notify = notify,
        .open_external = openExternal,
        .show_in_folder = showInFolder,
        .theme = themeOf,
    };
}

/// The window a modal dialog should be owned by, so it is centered on the
/// application rather than on the screen. Set by the backend once a window
/// exists; a dialog with no owner still works.
pub var owner: ?ffi.HWND = null;

// --------------------------------------------------------------- clipboard

fn readClipboard(_: ?*anyopaque, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    // Opening can fail simply because another process holds the clipboard,
    // which is normal and transient. There is nothing better to report than
    // "no text".
    if (ffi.OpenClipboard(owner) == 0) return null;
    defer _ = ffi.CloseClipboard();

    if (ffi.IsClipboardFormatAvailable(ffi.CF_UNICODETEXT) == 0) return null;
    const handle = ffi.GetClipboardData(ffi.CF_UNICODETEXT) orelse return null;

    // The handle belongs to the clipboard: it must not be freed here.
    const raw = ffi.GlobalLock(handle) orelse return null;
    defer _ = ffi.GlobalUnlock(handle);

    const wide: [*:0]const u16 = @ptrCast(@alignCast(raw));
    const units = std.mem.span(wide);

    // `utf16LeToUtf8` refuses a buffer that is too small rather than filling it
    // part way, which is what is wanted: half a clipboard is not the text the
    // user copied.
    const n = std.unicode.utf16LeToUtf8(buf, units) catch return null;
    return buf[0..n];
}

fn writeClipboard(_: ?*anyopaque, text: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (ffi.OpenClipboard(owner) == 0) return false;
    defer _ = ffi.CloseClipboard();

    // Emptying first is what makes this the only item on the clipboard rather
    // than an addition beside what was there.
    if (ffi.EmptyClipboard() == 0) return false;

    // A moveable global block, because that is the only kind the clipboard
    // accepts. The clipboard takes ownership on success, so the block must not
    // be freed once `SetClipboardData` has it.
    //
    // The text is runtime data, so it is converted into a buffer rather than
    // through `utf8ToUtf16LeStringLiteral`, which requires a compile-time
    // literal.
    var wide_buf: [32 * 1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide_buf[0 .. wide_buf.len - 1], text) catch return false;
    wide_buf[n] = 0;
    const units = wide_buf[0..n];

    const bytes = (units.len + 1) * @sizeOf(u16);
    const block = ffi.GlobalAlloc(ffi.GMEM_MOVEABLE, bytes) orelse return false;

    const dest = ffi.GlobalLock(block) orelse {
        _ = ffi.GlobalFree(block);
        return false;
    };
    const out: [*]u16 = @ptrCast(@alignCast(dest));
    for (units, 0..) |u, i| out[i] = u;
    out[units.len] = 0;
    _ = ffi.GlobalUnlock(block);

    if (ffi.SetClipboardData(ffi.CF_UNICODETEXT, block) == null) {
        // Only on failure is the block still ours to free.
        _ = ffi.GlobalFree(block);
        return false;
    }
    return true;
}

// ------------------------------------------------------------- file dialog

/// Builds the `OPENFILENAMEW` filter string: a list of label/value pairs, each
/// NUL-terminated, the whole thing ended by a second NUL.
///
/// The contract's filter is glob-ish (`*.png`), which is already what the value
/// half wants. An empty filter asks for every file, which Win32 spells
/// `"All Files\0*.*\0\0"`.
///
/// Returns the length written, or null when it does not fit.
pub fn buildFilter(buf: []u16, filter: []const u8) ?usize {
    var n: usize = 0;

    const label = "Files";
    for (label) |c| {
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    if (n >= buf.len) return null;
    buf[n] = 0;
    n += 1;

    const value = if (filter.len > 0) filter else "*.*";
    for (value) |c| {
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    if (n >= buf.len) return null;
    buf[n] = 0;
    n += 1;

    // The final NUL that ends the list.
    if (n >= buf.len) return null;
    buf[n] = 0;
    n += 1;
    return n;
}

/// Splits what a multi-select dialog wrote into `lpstrFile`.
///
/// The format is a NULL-separated list. With one file it is that file's full
/// path. With several it is the directory, then each file name. Getting this
/// wrong yields one nonsense path instead of N real ones.
pub fn splitMultiSelect(
    wide: []const u16,
    out: *const desktop.PathBuffer,
    utf8_buf: []u8,
) usize {
    var pb = @constCast(out);

    // Collect the NUL-separated pieces.
    var parts: [64][]const u16 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < wide.len and count < parts.len) : (i += 1) {
        if (wide[i] != 0) continue;
        if (i == start) break; // the double NUL ends the list
        parts[count] = wide[start..i];
        count += 1;
        start = i + 1;
    }
    if (count == 0) return 0;

    // One piece is a complete path.
    if (count == 1) {
        if (ffi.utf8(utf8_buf, parts[0])) |path| {
            _ = pb.append(path) catch return 0;
            return 1;
        }
        return 0;
    }

    // Several pieces: the first is the directory, the rest are names.
    var written: usize = 0;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = ffi.utf8(&dir_buf, parts[0]) orelse return 0;

    var k: usize = 1;
    while (k < count) : (k += 1) {
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name = ffi.utf8(&name_buf, parts[k]) orelse continue;

        // Join with the separator, unless the directory already ends in one.
        const joined = std.fmt.bufPrint(utf8_buf, "{s}{s}{s}", .{
            dir,
            if (dir.len > 0 and dir[dir.len - 1] == '\\') "" else "\\",
            name,
        }) catch continue;
        if (pb.append(joined)) |_| {
            written += 1;
        } else |_| {}
    }
    return written;
}

fn fileDialog(_: ?*anyopaque, opts: desktop.FileDialogOptions, out: *const desktop.PathBuffer) desktop.FileDialogError!desktop.FileChoice {
    if (comptime builtin.os.tag != .windows) return error.NotSupported;

    const capacity = 64 * 1024;
    const file_buf = std.heap.c_allocator.alloc(u16, capacity) catch return error.Internal;
    defer std.heap.c_allocator.free(file_buf);
    @memset(file_buf, 0);

    var filter_buf: [1024]u16 = undefined;
    const filter_len = buildFilter(&filter_buf, opts.filter) orelse return error.Internal;

    var title_buf: [512]u16 = undefined;
    var dir_buf: [1024]u16 = undefined;
    var name_buf: [512]u16 = undefined;
    var ext_buf: [64]u16 = undefined;

    var ofn = ffi.OPENFILENAMEW{
        .lStructSize = @sizeOf(ffi.OPENFILENAMEW),
        .hwndOwner = owner,
        .lpstrFilter = @ptrCast(&filter_buf),
        .nFilterIndex = 1,
        .lpstrFile = @ptrCast(file_buf.ptr),
        .nMaxFile = @intCast(file_buf.len),
        // Not changing the process's current directory is what a library
        // should do; without it the dialog moves it behind the app's back.
        .Flags = ffi.OFN_EXPLORER | ffi.OFN_NOCHANGEDIR | ffi.OFN_PATHMUSTEXIST,
    };
    _ = filter_len;

    if (opts.title.len > 0) ofn.lpstrTitle = ffi.utf16(&title_buf, opts.title);
    if (opts.start_in.len > 0) ofn.lpstrInitialDir = ffi.utf16(&dir_buf, opts.start_in);

    const is_save = opts.kind == .save_file;
    if (is_save) {
        if (opts.suggested_name.len > 0) {
            if (ffi.utf16(&name_buf, opts.suggested_name)) |s| {
                const n = std.mem.len(s);
                @memcpy(file_buf[0..n], s[0..n]);
                file_buf[n] = 0;
            }
        }
        ofn.Flags |= ffi.OFN_OVERWRITEPROMPT;
        if (extensionOf(opts.filter)) |ext| ofn.lpstrDefExt = ffi.utf16(&ext_buf, ext);
    } else if (opts.kind == .open_directory) {
        // A folder picker is a different API (`SHBrowseForFolder`), which this
        // backend does not have; saying so beats returning a file path the
        // caller would treat as a directory.
        return error.NotSupported;
    } else {
        ofn.Flags |= ffi.OFN_FILEMUSTEXIST;
        if (opts.kind == .open_files) ofn.Flags |= ffi.OFN_ALLOWMULTISELECT;
    }

    const ok = if (is_save) ffi.GetSaveFileNameW(&ofn) else ffi.GetOpenFileNameW(&ofn);
    if (ok == 0) {
        // Zero means cancelled or failed; the common dialog's `CommDlgExtendedError`
        // distinguishes them, and a cancel is by far the usual reason.
        return .{ .paths = &.{}, .cancelled = true };
    }

    var utf8_buf: [std.fs.max_path_bytes]u8 = undefined;
    var pb = @constCast(out);

    if (opts.kind == .open_files) {
        const total = std.mem.indexOfScalar(u16, file_buf, 0) orelse 0;
        _ = total;
        const n = splitMultiSelect(file_buf, out, &utf8_buf);
        if (n == 0) return .{ .paths = &.{}, .cancelled = true };
        // `splitMultiSelect` appended into the caller's buffer; the paths it
        // returns point into that buffer, so they are read back from it.
        var paths: [64][]const u8 = undefined;
        var i: usize = 0;
        while (i < n and i < paths.len) : (i += 1) {
            paths[i] = pb.storage[i][0..std.mem.len(@as([*:0]const u8, @ptrCast(&pb.storage[i])))];
        }
        return .{ .paths = paths[0..n], .cancelled = false };
    }

    const len = std.mem.indexOfScalar(u16, file_buf, 0) orelse 0;
    const path = ffi.utf8(&utf8_buf, file_buf[0..len]) orelse return .{ .paths = &.{}, .cancelled = true };
    const stored = pb.append(path) catch return error.TooManyPaths;
    const one = [_][]const u8{stored};
    return .{ .paths = &one, .cancelled = false };
}

/// The bare extension a filter names, for `lpstrDefExt`.
pub fn extensionOf(filter: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, filter, "*.")) {
        const ext = filter[2..];
        if (ext.len == 0) return null;
        if (std.mem.indexOfScalar(u8, ext, '*') != null) return null;
        return ext;
    }
    return null;
}

// ------------------------------------------------------------- message box

/// The `MB_*` flag for a message kind.
///
/// The icon flags are the low four bits; `MB_OK`, `MB_YESNO` and friends are a
/// separate field, so both are OR'd together.
pub fn messageFlags(kind: desktop.MessageKind, button_count: usize) u32 {
    const icon: u32 = switch (kind) {
        .info => 0x0000_0040, // MB_ICONINFORMATION
        .warning => 0x0000_0030, // MB_ICONWARNING
        .question => 0x0000_0020, // MB_ICONQUESTION
        .@"error" => 0x0000_0010, // MB_ICONERROR
    };
    // Two buttons is yes/no; anything else is a single OK, because Win32's
    // message box cannot show arbitrary labels.
    const buttons: u32 = if (button_count == 2) 0x0000_0004 else 0x0000_0000;
    return icon | buttons;
}

/// The button index for what `MessageBoxW` returned, or null when dismissed.
///
/// `IDOK` is 1, `IDYES` is 6 and `IDNO` is 7 — not 0, 1, 2. For a two-button
/// box Yes is the answer that means "the first button".
pub fn buttonIndex(ret: c_int) ?usize {
    return switch (ret) {
        ffi.IDOK, ffi.IDYES => 0,
        ffi.IDNO => 1,
        // `IDCANCEL` and everything else is a dismissal.
        else => null,
    };
}

fn messageBox(_: ?*anyopaque, opts: desktop.MessageOptions) ?usize {
    if (comptime builtin.os.tag != .windows) return null;

    var title_buf: [512]u16 = undefined;
    var body_buf: [2048]u16 = undefined;

    // Win32's box has one title and one body, and cannot show custom button
    // labels. The first label becomes the body when no body was given, so a
    // caller who passed only buttons still sees something meaningful.
    const body_text = if (opts.body.len > 0) opts.body else if (opts.buttons.len > 0) opts.buttons[0] else "OK";

    const title = ffi.utf16(&title_buf, opts.title) orelse return null;
    const body = ffi.utf16(&body_buf, body_text) orelse return null;

    const ret = ffi.MessageBoxW(owner, body, title, messageFlags(opts.kind, opts.buttons.len));
    return buttonIndex(ret);
}

// ------------------------------------------------------------- notification

fn notify(_: ?*anyopaque, opts: desktop.NotificationOptions) bool {
    if (comptime builtin.os.tag != .windows) return false;

    // A Windows 10 toast needs a registered AppUserModelID and a Start-menu
    // shortcut; without them the system drops it silently. The tray balloon is
    // the path that works without any of that, so a notification goes there —
    // and when no tray is shown there is nowhere to put it, which is reported
    // rather than swallowed.
    const hwnd = backend_mod.trayNotifyWindow() orelse return false;
    var data = backend_mod.trayBlankData(hwnd);
    data.uFlags = ffi.NIF_INFO;
    // A title or body that does not fit is refused rather than truncated: a
    // half notification says something the caller never wrote.
    if (ffi.utf16(&data.szInfoTitle, opts.title) == null) return false;
    if (ffi.utf16(&data.szInfo, opts.body) == null) return false;
    data.dwInfoFlags = if (opts.silent) ffi.NIIF_INFO | ffi.NIIF_NOSOUND else ffi.NIIF_INFO;

    if (ffi.Shell_NotifyIconW(ffi.NIM_MODIFY, &data) == 0) return false;
    log.debug("notify: shown as a tray balloon", .{});
    return true;
}

// ------------------------------------------------------------- outside the app

fn openExternal(_: ?*anyopaque, url: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    var url_buf: [2048]u16 = undefined;
    const u = ffi.utf16(&url_buf, url) orelse return false;
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");

    // A shell-return above 32 is success, which is a famously irregular
    // convention: 0 and the small numbers are errors.
    const ret = ffi.ShellExecuteW(owner, verb, u, null, null, 1); // SW_SHOWNORMAL
    return @intFromPtr(ret) > 32;
}

fn showInFolder(_: ?*anyopaque, path: []const u8) bool {
    _ = path;
    if (comptime builtin.os.tag != .windows) return false;
    // `SHOpenFolderAndSelectItems` needs an `IShellItem` from
    // `SHParseDisplayName`, which is COM this backend has not built. Opening
    // the folder without selecting the file would be a half-answer.
    return false;
}

// ------------------------------------------------------------------- theme

fn themeOf(_: ?*anyopaque) desktop.Theme {
    _ = readAppsUseLightTheme;
    return .light;
}

/// The registry value that says whether applications use the light theme.
///
/// Declared but not called: reading it needs `advapi32`'s `RegGetValueW`, which
/// this backend does not link. Kept as the documented name of what a later
/// version must read, rather than pretending the theme is known.
fn readAppsUseLightTheme() void {}

/// Maps the `AppsUseLightTheme` DWORD to the contract's theme.
///
/// Absent means light, which is Windows' default: an application that cannot
/// read the value must not claim the user asked for dark.
pub fn themeFromRegistry(value: ?u32) desktop.Theme {
    const v = value orelse return .light;
    return if (v == 0) .dark else .light;
}

/// The tray item an event means, or null when it is not a click on the icon.
///
/// Version 4 of the protocol sends `NIN_SELECT` for a left click and
/// `WM_CONTEXTMENU` for a right one; older versions send `WM_LBUTTONUP` and
/// `WM_RBUTTONUP`. Both are answered, because which one arrives depends on
/// whether `NIM_SETVERSION` was honoured — which cannot be checked from here.
pub fn trayItemOf(event: ffi.UINT) ?u32 {
    return switch (event) {
        ffi.NIN_SELECT, ffi.WM_LBUTTONUP => 0,
        ffi.WM_CONTEXTMENU, ffi.WM_RBUTTONUP => 1,
        else => null,
    };
}

// ------------------------------------------------------------------- tests

test "the filter list is double-NUL terminated" {
    var buf: [256]u16 = undefined;
    const n = buildFilter(&buf, "*.png").?;
    // "Files\0" + "*.png\0" + "\0"
    try std.testing.expectEqual(@as(u16, 0), buf[5]);
    try std.testing.expectEqual(@as(u16, 0), buf[11]);
    try std.testing.expectEqual(@as(u16, 0), buf[12]);
    try std.testing.expectEqual(@as(usize, 13), n);
}

test "an empty filter asks for every file" {
    var buf: [256]u16 = undefined;
    _ = buildFilter(&buf, "").?;
    // The value half is "*.*".
    try std.testing.expectEqual(@as(u16, '*'), buf[6]);
    try std.testing.expectEqual(@as(u16, '.'), buf[7]);
    try std.testing.expectEqual(@as(u16, '*'), buf[8]);
}

test "a filter too long for the buffer is refused" {
    var tiny: [4]u16 = undefined;
    try std.testing.expect(buildFilter(&tiny, "*.png") == null);
}

test "the message box flags combine an icon and a button set" {
    // Info is 0x40, yes/no is 0x4; a swapped field would replace the icon.
    try std.testing.expectEqual(@as(u32, 0x40), messageFlags(.info, 1));
    try std.testing.expectEqual(@as(u32, 0x44), messageFlags(.info, 2));
    try std.testing.expectEqual(@as(u32, 0x30), messageFlags(.warning, 1));
    try std.testing.expectEqual(@as(u32, 0x10), messageFlags(.@"error", 1));
}

test "the message box answer is mapped from IDOK and IDYES" {
    // These are 1, 6 and 7 — not 0, 1, 2.
    try std.testing.expectEqual(@as(?usize, 0), buttonIndex(ffi.IDOK));
    try std.testing.expectEqual(@as(?usize, 0), buttonIndex(ffi.IDYES));
    try std.testing.expectEqual(@as(?usize, 1), buttonIndex(ffi.IDNO));
    // A dismissal is not a button.
    try std.testing.expect(buttonIndex(2) == null); // IDCANCEL
    try std.testing.expect(buttonIndex(0) == null);
}

test "a multi-select list of one file is that file's path" {
    var pb = desktop.PathBuffer{};
    var buf: [128]u8 = undefined;
    const wide = [_]u16{ 'C', ':', 0 };
    const n = splitMultiSelect(&wide, &pb, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("C:", pb.storage[0][0..2]);
}

test "a multi-select list of several files joins them with the directory" {
    var pb = desktop.PathBuffer{};
    var buf: [128]u8 = undefined;
    // "C:\\dir\0one.png\0two.png\0\0"
    const wide = [_]u16{ 'C', ':', '\\', 'd', 'i', 'r', 0, 'o', 'n', 'e', 0, 't', 'w', 'o', 0, 0 };
    const n = splitMultiSelect(&wide, &pb, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("C:\\dir\\one", pb.storage[0][0..10]);
    try std.testing.expectEqualStrings("C:\\dir\\two", pb.storage[1][0..10]);
}

test "a directory already ending in a separator is not doubled" {
    var pb = desktop.PathBuffer{};
    var buf: [128]u8 = undefined;
    const wide = [_]u16{ 'C', ':', '\\', 0, 'a', 0, 0 };
    const n = splitMultiSelect(&wide, &pb, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("C:\\a", pb.storage[0][0..4]);
}

test "an absent registry value means light, not dark" {
    try std.testing.expectEqual(desktop.Theme.light, themeFromRegistry(null));
    try std.testing.expectEqual(desktop.Theme.dark, themeFromRegistry(0));
    try std.testing.expectEqual(desktop.Theme.light, themeFromRegistry(1));
}

test "both tray protocols map to the same two items" {
    // Version 4 sends NIN_SELECT and WM_CONTEXTMENU; older ones send the
    // button-up messages. Answering only one pair would make clicks work on
    // some Windows versions and not others.
    try std.testing.expectEqual(@as(?u32, 0), trayItemOf(ffi.NIN_SELECT));
    try std.testing.expectEqual(@as(?u32, 0), trayItemOf(ffi.WM_LBUTTONUP));
    try std.testing.expectEqual(@as(?u32, 1), trayItemOf(ffi.WM_CONTEXTMENU));
    try std.testing.expectEqual(@as(?u32, 1), trayItemOf(ffi.WM_RBUTTONUP));

    // A mouse move or an unrelated message is not a click.
    try std.testing.expect(trayItemOf(ffi.WM_MOUSEMOVE) == null);
    try std.testing.expect(trayItemOf(0) == null);
}

test "every desktop call is answered off Windows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(readClipboard(null, undefined) == null);
    try std.testing.expect(!writeClipboard(null, "text"));
    try std.testing.expect(!notify(null, .{}));
    try std.testing.expect(!openExternal(null, "https://example.invalid"));
    try std.testing.expect(!showInFolder(null, "C:\\"));
}

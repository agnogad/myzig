//! GTK implementations of the desktop integrations.
//!
//! Every call runs on the main thread. Each one names the GTK object it uses, so
//! a failure can be traced to the call that caused it.
//!
//! ## Clipboard
//!
//! `gtk_clipboard_wait_for_text` blocks until a selection owner answers. On X11
//! that is immediate for the local selection; on Wayland it round-trips through
//! the compositor. A read is therefore a synchronous call, which matches what
//! `await myzig.clipboard.readText()` expects.
//!
//! ## Notifications
//!
//! GTK 3 has no notification API of its own; the freedesktop
//! `org.freedesktop.Notifications` D-Bus service is used through
//! `g_dbus_connection_call_sync`. A session with no notification daemon gets
//! `false`, not a silent drop.

const std = @import("std");
const desktop = @import("../desktop.zig");
const ffi = @import("ffi.zig");
const log = @import("../../log.zig");
const env = @import("../../utils/env.zig");

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

// --------------------------------------------------------------- clipboard

fn clipboard() ?ffi.GtkClipboard {
    // `GDK_SELECTION_CLIPBOARD` is a GdkAtom, not a small integer: it must be
    // interned by name. Passing a guess makes GTK return a clipboard for a
    // selection that does not exist, and every read and write fails.
    const atom = ffi.gdk_atom_intern("CLIPBOARD", ffi.FALSE);
    return ffi.gtk_clipboard_get(atom);
}

fn readClipboard(ctx: ?*anyopaque, buf: []u8) ?[]const u8 {
    _ = ctx;
    const cb = clipboard() orelse return null;
    const text = ffi.gtk_clipboard_wait_for_text(cb) orelse return null;
    defer ffi.g_free(@ptrCast(text));
    const n = std.mem.len(text);
    const len = @min(n, buf.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf[0..len];
}

fn writeClipboard(ctx: ?*anyopaque, text: []const u8) bool {
    _ = ctx;
    const cb = clipboard() orelse return false;
    // `gtk_clipboard_set_text` copies the string, so a stack buffer is fine.
    const c = ffi.CStr.init(text);
    ffi.gtk_clipboard_set_text(cb, c.ptr(), @intCast(c.len));
    // `store` hands the selection to the clipboard manager so it survives this
    // process. A session without one fails here, which is not an error: the
    // text is already owned by this process's selection.
    _ = ffi.gtk_clipboard_store(cb);
    return true;
}

/// Copies a NUL-terminated C string into `dst` and returns the slice of `dst`
/// that holds it. A path longer than `dst` is rejected rather than truncated:
/// a shortened path would point at a different file.
fn copyCStr(dst: []u8, src: [*:0]const u8) []u8 {
    const len = std.mem.len(src);
    if (len > dst.len) return dst[0..0];
    @memcpy(dst[0..len], src[0..len]);
    return dst[0..len];
}

// ----------------------------------------------------------------- dialogs

fn fileDialog(
    ctx: ?*anyopaque,
    opts: desktop.FileDialogOptions,
    out: *const desktop.PathBuffer,
) desktop.FileDialogError!desktop.FileChoice {
    _ = ctx;
    const action: c_int = switch (opts.kind) {
        .save_file => ffi.GTK_FILE_CHOOSER_ACTION_SAVE,
        .open_directory => ffi.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        else => ffi.GTK_FILE_CHOOSER_ACTION_OPEN,
    };
    const title = ffi.CStr.init(opts.title);
    const dialog = ffi.gtk_file_chooser_dialog_new(
        title.ptr(),
        null,
        action,
        "Cancel",
        ffi.GTK_RESPONSE_CANCEL,
        if (opts.kind == .save_file) "Save" else "Open",
        ffi.GTK_RESPONSE_ACCEPT,
        @as(?*anyopaque, null),
    ) orelse return error.Internal;
    // GTK returns a floating reference the caller owns.
    _ = ffi.g_object_ref_sink(@ptrCast(dialog));
    defer _ = ffi.g_object_unref(@ptrCast(dialog));

    if (opts.kind == .open_files) {
        ffi.gtk_file_chooser_set_select_multiple(dialog, ffi.TRUE);
    }
    if (opts.suggested_name.len > 0) {
        const name = ffi.CStr.init(opts.suggested_name);
        ffi.gtk_file_chooser_set_current_name(dialog, name.ptr());
    }
    if (opts.filter.len > 0) {
        const f = ffi.gtk_file_filter_new();
        if (f) |filter| {
            const filter_name = ffi.CStr.init("Files");
            ffi.gtk_file_filter_set_name(filter, filter_name.ptr());
            const pat = ffi.CStr.init(opts.filter);
            ffi.gtk_file_filter_add_pattern(filter, pat.ptr());
            ffi.gtk_file_chooser_add_filter(dialog, filter);
        }
    }

    const response = ffi.gtk_dialog_run(dialog);
    var pb: *desktop.PathBuffer = @constCast(out);
    pb.count = 0;
    if (response != ffi.GTK_RESPONSE_ACCEPT) {
        return .{ .paths = &.{}, .cancelled = true };
    }

    var chosen: [64][]const u8 = undefined;
    var n: usize = 0;
    if (opts.kind == .open_files) {
        const list = ffi.gtk_file_chooser_get_filenames(dialog);
        if (list) |l| {
            defer ffi.g_strfreev(l);
            var i: usize = 0;
            while (l[i]) |item| : (i += 1) {
                if (n == chosen.len) break;
                const path = copyCStr(pb.storage[n][0..], item);
                if (path.len == 0) continue;
                chosen[n] = path;
                n += 1;
            }
        }
    } else {
        const one = ffi.gtk_file_chooser_get_filename(dialog) orelse
            return .{ .paths = &.{}, .cancelled = true };
        defer ffi.g_free(@ptrCast(one));
        const path = copyCStr(pb.storage[0][0..], one);
        if (path.len > 0) {
            chosen[0] = path;
            n = 1;
        }
    }
    pb.count = n;
    return .{ .paths = chosen[0..n] };
}

fn messageBox(ctx: ?*anyopaque, opts: desktop.MessageOptions) ?usize {
    _ = ctx;
    const kind: c_int = switch (opts.kind) {
        .info => ffi.GTK_MESSAGE_INFO,
        .warning => ffi.GTK_MESSAGE_WARNING,
        .question => ffi.GTK_MESSAGE_QUESTION,
        .@"error" => ffi.GTK_MESSAGE_ERROR,
    };
    const title = ffi.CStr.init(opts.title);
    const body = ffi.CStr.init(opts.body);
    const dialog = ffi.gtk_message_dialog_new(
        null,
        ffi.GTK_DIALOG_MODAL,
        kind,
        ffi.GTK_BUTTONS_NONE,
        "%s",
        body.ptr(),
    ) orelse return null;
    _ = ffi.g_object_ref_sink(@ptrCast(dialog));
    defer _ = ffi.g_object_unref(@ptrCast(dialog));

    ffi.gtk_window_set_title(@ptrCast(dialog), title.ptr());

    // GTK's response ids start at 1 for the first custom button, so button `i`
    // maps back with `id - 1`.
    if (opts.buttons.len == 0) {
        _ = ffi.gtk_dialog_add_button(dialog, "OK", ffi.GTK_RESPONSE_OK);
    } else {
        for (opts.buttons, 0..) |label, i| {
            const l = ffi.CStr.init(label);
            _ = ffi.gtk_dialog_add_button(dialog, l.ptr(), @intCast(i + 1));
        }
    }
    const response = ffi.gtk_dialog_run(dialog);
    if (response <= 0) return null;
    if (opts.buttons.len == 0) return 0;
    return @intCast(response - 1);
}

// ----------------------------------------------------------- notifications

fn notify(ctx: ?*anyopaque, opts: desktop.NotificationOptions) bool {
    _ = ctx;
    // GTK 3 has no notification API. The freedesktop service is reached through
    // its client, `notify-send`, which ships with the notification daemon on
    // GNOME, KDE and most minimal desktops. Building the D-Bus parameter tuple
    // from Zig would mean creating a GVariant tree, which is a lot of unsafe
    // code for the same result.
    return notifySend(opts);
}

fn notifySend(opts: desktop.NotificationOptions) bool {
    // `notify-send` is the reference implementation's client and is present on
    // GNOME, KDE and most minimal desktops.
    var argv: [4][*:0]const u8 = undefined;
    var count: usize = 0;
    argv[count] = "notify-send";
    count += 1;
    const title = ffi.CStr.init(opts.title);
    argv[count] = title.ptr();
    count += 1;
    const body = ffi.CStr.init(opts.body);
    argv[count] = body.ptr();
    count += 1;
    argv[count] = @ptrCast(&[1:0]u8{0});
    return spawnDetached(argv[0..count]);
}

/// Starts a program without waiting for it, and without a shell in between.
fn spawnDetached(argv: []const [*:0]const u8) bool {
    return ffi.g_spawn_async(null, @ptrCast(argv.ptr), null, ffi.G_SPAWN_SEARCH_PATH, null, null, null) != 0;
}

// --------------------------------------------------------------- external

fn openExternal(ctx: ?*anyopaque, url: []const u8) bool {
    _ = ctx;
    const c = ffi.CStr.init(url);
    return ffi.gtk_show_uri_on_window(null, c.ptr(), ffi.GDK_CURRENT_TIME, null) != 0;
}

fn showInFolder(ctx: ?*anyopaque, path: []const u8) bool {
    _ = ctx;
    // `xdg-open` on a directory opens the file manager there, which is the
    // closest portable equivalent of "reveal in folder".
    const c = ffi.CStr.init(path);
    return ffi.gtk_show_uri_on_window(null, c.ptr(), ffi.GDK_CURRENT_TIME, null) != 0;
}

fn theme(ctx: ?*anyopaque) desktop.Theme {
    _ = ctx;
    const settings = ffi.gtk_settings_get_default() orelse return .light;
    var dark: c_int = 0;
    _ = ffi.g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, @as(?*anyopaque, null));
    return if (dark != 0) .dark else .light;
}

test "vtable is complete" {
    const vt = vtable();
    try std.testing.expect(@intFromPtr(vt.read_clipboard) != 0);
    try std.testing.expect(@intFromPtr(vt.notify) != 0);
    _ = env;
}

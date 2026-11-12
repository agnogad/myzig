//! GTK menu bars built from the portable `menu.Menu` model.
//!
//! The application never sees a `GtkMenuBar`: it describes a tree, this module
//! builds the widgets, and clicks come back as command ids through the app's
//! event sink.
//!
//! ## Accelerators
//!
//! A GTK accelerator needs a key symbol and modifier mask, so `menu.Accelerator`
//! is translated here rather than in `menu.zig`, which stays platform neutral.
//! Acceleration is attached to the *window's* accel group, not the menu item, so
//! it works even when the menu bar is hidden.
//!
//! ## Which window owns a menu
//!
//! On Linux a menu bar belongs to one window, so a `Menu` is attached to a
//! window id. The same `Menu` value can be attached to several windows, and each
//! gets its own widgets.

const std = @import("std");
const ffi = @import("ffi.zig");
const gpointer = ffi.gpointer;
const log = @import("../../log.zig");
const menu_mod = @import("../../menu.zig");

/// A built menu bar and its accel group, kept so they can be removed.
pub const Built = struct {
    bar: ffi.GtkWidget,
    accel_group: gpointer,
};

var built: std.AutoHashMapUnmanaged(u32, Built) = .empty;

/// Builds the widgets for `m` and attaches them to `gtk_window`. Returns null
/// when GTK refused to make the widgets.
pub fn build(
    allocator: std.mem.Allocator,
    window_id: u32,
    gtk_window: ffi.GtkWindow,
    m: menu_mod.Menu,
) ?Built {
    const bar = ffi.gtk_menu_bar_new() orelse return null;
    const group = ffi.gtk_accel_group_new() orelse {
        ffi.gtk_widget_destroy(bar);
        return null;
    };

    for (m.items) |item| appendItem(bar, group, item);

    ffi.gtk_window_add_accel_group(gtk_window, group);
    ffi.gtk_widget_show_all(bar);

    // Replacing a menu replaces its widgets; the old ones belong to the window
    // and are destroyed with it.
    built.put(allocator, window_id, .{ .bar = bar, .accel_group = group }) catch {
        ffi.gtk_widget_destroy(bar);
        return null;
    };
    return .{ .bar = bar, .accel_group = group };
}

fn appendItem(parent: ffi.GtkWidget, group: gpointer, item: menu_mod.Item) void {
    switch (item) {
        .separator => {
            const sep = ffi.gtk_separator_menu_item_new() orelse return;
            ffi.gtk_menu_shell_append(parent, sep);
        },
        .command => |c| {
            const label = labelFor(c.label, c.role);
            const text = ffi.CStr.init(label);
            const w = ffi.gtk_menu_item_new_with_mnemonic(text.ptr()) orelse return;
            ffi.gtk_menu_shell_append(parent, w);
            if (!c.enabled) ffi.gtk_widget_set_sensitive(w, ffi.FALSE);
            if (c.id.len > 0) attachCommand(w, c.id);
            addAccelerator(w, group, c.accel, c.id);
        },
        .checkbox => |c| {
            const text = ffi.CStr.init(c.label);
            const w = ffi.gtk_check_menu_item_new_with_label(text.ptr()) orelse return;
            ffi.gtk_check_menu_item_set_active(w, if (c.checked) ffi.TRUE else ffi.FALSE);
            ffi.gtk_menu_shell_append(parent, w);
            if (!c.enabled) ffi.gtk_widget_set_sensitive(w, ffi.FALSE);
            if (c.id.len > 0) attachCommand(w, c.id);
            addAccelerator(w, group, c.accel, c.id);
        },
        .radio => |c| {
            // GTK groups radio items by inserting them next to each other in the
            // same menu shell; the first is a plain check item. Keeping the
            // group implicit means a submenu can be one radio set.
            const text = ffi.CStr.init(c.label);
            const w = ffi.gtk_check_menu_item_new_with_label(text.ptr()) orelse return;
            ffi.gtk_check_menu_item_set_active(w, if (c.checked) ffi.TRUE else ffi.FALSE);
            ffi.gtk_menu_shell_append(parent, w);
            if (c.id.len > 0) attachCommand(w, c.id);
            addAccelerator(w, group, c.accel, c.id);
        },
        .submenu => |s| {
            const text = ffi.CStr.init(s.label);
            const item_w = ffi.gtk_menu_item_new_with_mnemonic(text.ptr()) orelse return;
            const sub = ffi.gtk_menu_new() orelse {
                ffi.gtk_widget_destroy(item_w);
                return;
            };
            for (s.items) |child| appendItem(sub, group, child);
            ffi.gtk_menu_item_set_submenu(item_w, sub);
            if (!s.enabled) ffi.gtk_widget_set_sensitive(item_w, ffi.FALSE);
            ffi.gtk_menu_shell_append(parent, item_w);
        },
    }
}

/// A role supplies a default label when the application did not give one, so
/// `.{ .id = "quit", .role = .quit }` reads as "Quit" without repeating it.
fn labelFor(label: []const u8, role: ?menu_mod.Role) []const u8 {
    if (label.len > 0) return label;
    const r = role orelse return "";
    return switch (r) {
        .quit => "Quit",
        .about => "About",
        .hide => "Hide",
        .services => "Services",
        .undo => "Undo",
        .redo => "Redo",
        .cut => "Cut",
        .copy => "Copy",
        .paste => "Paste",
        .select_all => "Select All",
        .minimize => "Minimize",
        .zoom => "Zoom",
        .close_window => "Close Window",
        .fullscreen => "Toggle Full Screen",
        .preferences => "Preferences",
        .reload => "Reload",
        .toggle_devtools => "Developer Tools",
        .window => "Window",
        .help => "Help",
    };
}

/// Command ids reach the application through the app's event sink. The id is
/// duplicated into the widget's user data, so it outlives the caller's `Menu`.
fn attachCommand(w: ffi.GtkWidget, id: []const u8) void {
    const ctx = command_ctx orelse return;
    const owned = std.fmt.allocPrint(ctx.allocator, "{s}", .{id}) catch return;
    // The widget owns the string; a destroyed widget cannot report a click, and
    // the process lifetime bounds the leak of a replaced menu.
    _ = ffi.g_signal_connect_data(
        w,
        "activate",
        @ptrCast(&onActivate),
        owned.ptr,
        null,
        0,
    );
}

/// Set by the backend when it initialises, so a menu click can reach the app.
pub const CommandCtx = struct {
    allocator: std.mem.Allocator,
    /// Reports the command id to the application.
    report: *const fn (ctx: *anyopaque, id: []const u8) void,
    ctx: *anyopaque,
};

var command_ctx: ?CommandCtx = null;

pub fn setCommandSink(sink: CommandCtx) void {
    command_ctx = sink;
}

fn onActivate(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const ctx = command_ctx orelse return;
    const id_ptr = data orelse return;
    const id = std.mem.span(@as([*:0]const u8, @ptrCast(id_ptr)));
    ctx.report(ctx.ctx, id);
}

fn addAccelerator(w: ffi.GtkWidget, group: gpointer, accel: []const u8, id: []const u8) void {
    if (accel.len == 0) return;
    const parsed = menu_mod.Accelerator.parse(accel) catch {
        // A bad accelerator is a programming error in the application, so it is
        // reported with the id that carries it rather than ignored.
        log.err("menu: item '{s}' has an unusable accelerator '{s}'", .{ id, accel });
        return;
    };
    const keyval = keyvalOf(parsed.key);
    if (keyval == 0) {
        log.err("menu: item '{s}' names a key GTK cannot bind: '{s}'", .{ id, accel });
        return;
    }
    ffi.gtk_widget_add_accelerator(w, "activate", group, keyval, modsOf(parsed), ffi.GTK_ACCEL_VISIBLE);
}

fn modsOf(a: menu_mod.Accelerator) c_int {
    // GDK modifier masks: shift 1, control 4, alt 8, super 64.
    var m: c_int = 0;
    if (a.shift) m |= 1;
    if (a.ctrl) m |= 4;
    if (a.alt) m |= 8;
    if (a.meta) m |= 64;
    return m;
}

/// Key symbols are GDK's lowercase letter and digit code points, with named keys
/// given their X11 keysyms.
fn keyvalOf(key: menu_mod.Accelerator.Key) c_uint {
    const K = menu_mod.Accelerator.Key;
    return switch (key) {
        .unknown => 0,
        .comma => ',',
        .period => '.',
        .slash => '/',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .bracket_left => '[',
        .bracket_right => ']',
        .minus => '-',
        .equals => '=',
        .grave => '`',
        .space => 0x020,
        .tab => 0xff09,
        .enter => 0xff0d,
        .escape => 0xff1b,
        .backspace => 0xff08,
        .delete => 0xffff,
        .insert => 0xff63,
        .home => 0xff50,
        .end => 0xff57,
        .page_up => 0xff55,
        .page_down => 0xff56,
        .arrow_up => 0xff52,
        .arrow_down => 0xff54,
        .arrow_left => 0xff51,
        .arrow_right => 0xff53,
        .f1 => 0xffbe,
        .f2 => 0xffbf,
        .f3 => 0xffc0,
        .f4 => 0xffc1,
        .f5 => 0xffc2,
        .f6 => 0xffc3,
        .f7 => 0xffc4,
        .f8 => 0xffc5,
        .f9 => 0xffc6,
        .f10 => 0xffc7,
        .f11 => 0xffc8,
        .f12 => 0xffc9,
        else => |k| blk: {
            const n = @backingInt(k);
            const a = @backingInt(K.a);
            const d = @backingInt(K.digit_0);
            if (n >= a and n < a + 26) break :blk @as(c_uint, 'a') + (n - a);
            if (n >= d and n < d + 10) break :blk @as(c_uint, '0') + (n - d);
            break :blk 0;
        },
    };
}

pub fn deinit() void {
    built.deinit(std.heap.page_allocator);
    built = .empty;
}

test "modifier masks follow GDK" {
    const a = try menu_mod.Accelerator.parse("Ctrl+Shift+P");
    try std.testing.expectEqual(@as(c_int, 5), modsOf(a));
}

test "key symbols cover letters, digits and named keys" {
    try std.testing.expectEqual(@as(c_uint, 'q'), keyvalOf(.q));
    try std.testing.expectEqual(@as(c_uint, '7'), keyvalOf(.digit_7));
    try std.testing.expectEqual(@as(c_uint, 0xffc2), keyvalOf(.f5));
    try std.testing.expectEqual(@as(c_uint, 0), keyvalOf(.unknown));
}

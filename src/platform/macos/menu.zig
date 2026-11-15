//! The macOS menu bar, built from the portable `menu.Menu` model.
//!
//! On macOS a menu bar belongs to the application, not to a window: there is
//! one bar in the top-left of the screen, and every window shares it. So a
//! `Menu` attached to any window installs `NSApp.mainMenu`, and the window id
//! is only used to keep command tags from colliding.
//!
//! ## How a click comes back
//!
//! An `NSMenuItem` carries a target, an action and a tag. The target is a
//! delegate object built at run time (`menuTarget`), the action is
//! `menuItemClicked:`, and the tag indexes a table of command ids — the model's
//! ids are strings, and an `NSMenuItem` holds only an integer. The delegate
//! sends the id through the app's event sink, exactly as the Linux backend does.
//!
//! ## Accelerators
//!
//! `NSMenuItem.keyEquivalent` is a single character plus a modifier mask, where
//! `NSCommandKeyMask` is 1 << 20 and `NSShiftKeyMask` is 1 << 17. `Ctrl` maps
//! to the Command key, because a Mac application's `Ctrl+N` is meant as the
//! platform's own shortcut.
//!
//! ## Testing
//!
//! Written against Apple's documentation and **never run**: there is no Mac
//! here. `docs/platforms.md` says so.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const menu_mod = @import("../../menu.zig");
const delegate = @import("delegate.zig");

/// Builds `m` and installs it as the application's menu bar. The ids it
/// contains are duplicated into the static table, so `m` may be freed after
/// this returns; that is what lets the core copy a menu into a window's arena.
pub fn install(ns_app: objc.ObjCId, m: menu_mod.Menu, s: @import("../backend.zig").EventSink) bool {
    if (comptime builtin.os.tag != .macos) return false;
    _ = delegate.register();

    _ = delegate.menuTarget(s) orelse return false;
    delegate.resetTags(s);

    const bar = objc.sendId1(objc.class("NSMenu") orelse return false, "alloc", null) orelse return false;
    const bar_init = objc.sendId1(bar, "initWithTitle:", delegate.nsString("") orelse "");
    if (bar_init == null) {
        objc.sendVoid(bar, "release");
        return false;
    }

    // macOS expects the application menu first. The one supplied is used if the
    // application asked for it by making its first entry an app menu;
    // otherwise a minimal one is added, because without it there is no Quit.
    var placed_app_menu = false;
    for (m.items) |item| {
        const sub = buildSubmenu(item) orelse continue;
        if (!placed_app_menu and isAppMenu(item)) {
            placed_app_menu = true;
        }
        objc.sendVoidId(bar_init, "addItem:", sub);
    }

    if (!placed_app_menu) {
        const app_menu = buildApplicationMenu() orelse return false;
        objc.sendVoidId(bar_init, "addItem:", app_menu);
    }

    objc.sendVoidId(ns_app, "setMainMenu:", bar_init);
    objc.sendVoid(bar_init, "release");
    return true;
}

/// Whether a top-level item is the application menu. A submenu whose id or
/// label is the application's own name is treated as one; nothing else is.
fn isAppMenu(item: menu_mod.Item) bool {
    return switch (item) {
        .submenu => |s| std.mem.eql(u8, s.id, "app") or std.mem.eql(u8, s.id, "app_menu"),
        else => false,
    };
}

/// A top-level entry: a submenu, which is all the bar itself holds.
fn buildSubmenu(item: menu_mod.Item) ?objc.ObjCId {
    const sub = switch (item) {
        .submenu => |s| s,
        else => return null,
    };
    const cls = objc.class("NSMenu") orelse return null;
    const allocated = objc.sendId1(cls, "alloc", null) orelse return null;
    const title = delegate.nsString(sub.label) orelse return null;
    defer objc.sendVoid(title, "release");
    const menu = objc.sendId1(allocated, "initWithTitle:", title) orelse return null;

    for (sub.items) |child| appendItem(menu, child);

    const holder_cls = objc.class("NSMenuItem") orelse return null;
    const holder_alloc = objc.sendId1(holder_cls, "alloc", null) orelse return null;
    const holder = objc.sendId1(holder_alloc, "init", null) orelse return null;
    objc.sendVoidId(holder, "setSubmenu:", menu);
    objc.sendVoid(menu, "release");
    if (!sub.enabled) objc.sendBool(holder, "setEnabled:", false);
    return holder;
}

fn appendItem(menu: objc.ObjCId, item: menu_mod.Item) void {
    switch (item) {
        .separator => {
            // `separatorItem` is a convenience that makes and autoreleases one;
            // it is retained here so the menu owns it explicitly.
            const cls = objc.class("NSMenuItem") orelse return;
            const sep = objc.sendGetId(cls, "separatorItem") orelse return;
            objc.sendVoidId(menu, "addItem:", sep);
        },
        .command => |c| {
            const mi = makeItem(c.label, c.accel, c.enabled) orelse return;
            tagTheItem(mi, c.id);
            objc.sendVoidId(menu, "addItem:", mi);
            objc.sendVoid(mi, "release");
        },
        .checkbox, .radio => |c| {
            const mi = makeItem(c.label, c.accel, c.enabled) orelse return;
            // A check mark is a state the item draws itself; the application
            // owns the truth and sends a new menu when it changes.
            objc.sendI64(mi, "setState:", if (c.checked) 1 else 0);
            tagTheItem(mi, c.id);
            objc.sendVoidId(menu, "addItem:", mi);
            objc.sendVoid(mi, "release");
        },
        .submenu => {
            const sub = buildSubmenu(item) orelse return;
            objc.sendVoidId(menu, "addItem:", sub);
            objc.sendVoid(sub, "release");
        },
    }
}

/// An item labelled `label`, wired to the shared target.
fn makeItem(label: []const u8, accel: []const u8, enabled: bool) ?objc.ObjCId {
    const title = delegate.nsString(label) orelse return null;
    defer objc.sendVoid(title, "release");

    const cls = objc.class("NSMenuItem") orelse return null;
    const allocated = objc.sendId1(cls, "alloc", null) orelse return null;

    // `initWithTitle:action:keyEquivalent:`. The action is a selector, and the
    // key equivalent is an *unmodified* character: the modifiers live on the
    // item, and are the same characters macOS prints in the menu.
    const a = menu_mod.Accelerator.parse(accel) catch menu_mod.Accelerator{ .key = .unknown };
    var key_buf = [4]u8{ 0, 0, 0, 0 };
    const key_text = keyEquivalent(a, &key_buf);
    const key: objc.ObjCId = delegate.nsString(key_text);
    defer objc.sendVoid(key, "release");

    const init_fn: *const fn (objc.ObjCId, ?objc.Sel, objc.ObjCId, ?objc.Sel, objc.ObjCId) callconv(.c) objc.ObjCId =
        @ptrCast(@alignCast(objc.msgSend()));
    const item = init_fn(allocated, objc.sel("initWithTitle:action:keyEquivalent:"), title, objc.sel("menuItemClicked:"), key);
    if (item == null) return null;

    if (delegate.menuTarget(delegate.currentSink() orelse return item)) |t| {
        objc.sendVoidId(item, "setTarget:", t);
    }

    objc.sendI64(item, "setKeyEquivalentModifierMask:", modifierMask(a));

    if (!enabled) objc.sendBool(item, "setEnabled:", false);
    return item;
}

/// The single character an item's key equivalent is, or "" for none.
fn keyEquivalent(a: menu_mod.Accelerator, buf: *[4]u8) []const u8 {
    // Letters and digits are contiguous runs in the enum, so one arithmetic
    // step selects the character; every other key is named.
    const n = @backingInt(a.key);
    const a_start = @backingInt(menu_mod.Accelerator.Key.a);
    const digit_start = @backingInt(menu_mod.Accelerator.Key.digit_0);
    const f_start = @backingInt(menu_mod.Accelerator.Key.f1);
    if (n >= a_start and n < a_start + letters.len) return letters[n - a_start];
    if (n >= digit_start and n < digit_start + digits.len) return digits[n - digit_start];
    return switch (a.key) {
        .unknown => "",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .minus => "-",
        .equals => "=",
        .grave => "`",
        .bracket_left => "[",
        .bracket_right => "]",
        .space => " ",
        .tab => "\t",
        .enter => "\r",
        .escape => "\x1b",
        .backspace => "\x08",
        .delete => "\x7f",
        else => blk: {
            // Function keys are private-use characters in AppKit: F1 is U+F704.
            if (n >= f_start and n < f_start + 12) {
                const cp: u21 = 0xF704 + @as(u21, @intCast(n - f_start));
                const len = std.unicode.utf8Encode(cp, buf) catch return "";
                break :blk buf[0..len];
            }
            break :blk "";
        },
    };
}

const letters = [_][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
};
const digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

/// The `NSEventModifierFlag` mask for an accelerator.
///
/// The model's `Ctrl` is the platform's Command key, because an application
/// that writes `Ctrl+N` means the shortcut a Mac user presses; `Cmd` and
/// `CmdOrCtrl` say so explicitly and land in the same place. A real Control
/// modifier cannot be expressed, which is a documented gap rather than a
/// surprise: Control is used for text editing on macOS, not for commands.
fn modifierMask(a: menu_mod.Accelerator) i64 {
    // Command 1 << 20, Shift 1 << 17, Option 1 << 19.
    var mask: i64 = 0;
    if (a.ctrl or a.meta) mask |= 1 << 20;
    if (a.shift) mask |= 1 << 17;
    if (a.alt) mask |= 1 << 19;
    return mask;
}

/// Records `id` and gives the item its tag.
fn tagTheItem(item: objc.ObjCId, id: []const u8) void {
    if (id.len == 0) return;
    const tag = delegate.tagFor(id);
    if (tag < 0) return;
    objc.sendI64(item, "setTag:", tag);
}

/// About, Hide, Quit: the three entries every Mac application menu has, wired
/// to AppKit's own actions so no code of ours is involved.
fn buildApplicationMenu() ?objc.ObjCId {
    const ns_menu = objc.class("NSMenu") orelse return null;
    const allocated = objc.sendId1(ns_menu, "alloc", null) orelse return null;
    const title = delegate.nsString("Application") orelse return null;
    defer objc.sendVoid(title, "release");
    const menu = objc.sendId1(allocated, "initWithTitle:", title) orelse return null;

    const pairs = [_]struct { label: []const u8, action: [*:0]const u8, key: []const u8 }{
        .{ .label = "About", .action = "orderFrontStandardAboutPanel:", .key = "" },
        .{ .label = "Hide", .action = "hide:", .key = "h" },
        .{ .label = "Quit", .action = "terminate:", .key = "q" },
    };

    for (pairs) |p| {
        const t = delegate.nsString(p.label) orelse continue;
        defer objc.sendVoid(t, "release");
        const k: objc.ObjCId = delegate.nsString(p.key);
        defer objc.sendVoid(k, "release");

        const item_cls = objc.class("NSMenuItem") orelse return menu;
        const item_alloc = objc.sendId1(item_cls, "alloc", null) orelse return menu;
        const init_fn: *const fn (objc.ObjCId, ?objc.Sel, objc.ObjCId, ?objc.Sel, objc.ObjCId) callconv(.c) objc.ObjCId =
            @ptrCast(@alignCast(objc.msgSend()));
        const item = init_fn(item_alloc, objc.sel("initWithTitle:action:keyEquivalent:"), t, objc.sel(p.action), k);
        if (item == null) continue;
        // The menu is the item's parent; AppKit then sends the action up the
        // responder chain, which reaches NSApp by itself.
        objc.sendVoidId(item, "setTarget:", objc.class("NSApplication"));
        if (p.key.len > 0) objc.sendI64(item, "setKeyEquivalentModifierMask:", 1 << 20);
        objc.sendVoidId(menu, "addItem:", item);
        objc.sendVoid(item, "release");
    }

    return menu;
}

test "a key equivalent is one character, and a function key is a private-use one" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("n", keyEquivalent(try menu_mod.Accelerator.parse("Ctrl+N"), &buf));
    try std.testing.expectEqualStrings("7", keyEquivalent(try menu_mod.Accelerator.parse("Ctrl+7"), &buf));
    // F1 is U+F704 in AppKit, which is three UTF-8 bytes.
    try std.testing.expectEqualStrings("\xEF\x9C\x84", keyEquivalent(try menu_mod.Accelerator.parse("F1"), &buf));
    try std.testing.expectEqualStrings("", keyEquivalent(.{ .key = .unknown }, &buf));
    try std.testing.expectEqualStrings("", keyEquivalent(.{ .key = .insert }, &buf));
}

test "an accelerator's modifiers map to AppKit's flags" {
    const shift_cmd = modifierMask(try menu_mod.Accelerator.parse("CmdOrCtrl+Shift+P"));
    try std.testing.expectEqual(@as(i64, (1 << 20) | (1 << 17)), shift_cmd);

    const plain = modifierMask(try menu_mod.Accelerator.parse("Ctrl+q"));
    try std.testing.expectEqual(@as(i64, 1 << 20), plain);

    const none = modifierMask(.{ .key = .q });
    try std.testing.expectEqual(@as(i64, 0), none);
}

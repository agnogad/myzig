//! Application menus.
//!
//! A menu is a **value**, not a platform handle. The application builds a tree
//! of `Item`s and the framework hands it to the backend, which translates it
//! into whatever that platform needs: a `GtkMenuBar` and a custom titlebar on
//! Linux, a Win32 `HMENU` on Windows, an `NSMenu` on macOS.
//!
//! Keeping the model here means:
//!
//! * The same menu definition produces the same menu on every platform.
//! * Accelerators (`"Ctrl+Q"`) are parsed once, in one place.
//! * A menu can be unit tested without a display.
//!
//! ## Roles
//!
//! Standard menu entries (Quit, Copy, Undo, About) differ per platform: macOS
//! expects them in the application menu, Windows in File/Edit. An `Item` can
//! declare a `role` instead of a label, and each backend places and labels it
//! the way its platform does.

const std = @import("std");

/// A menu tree. The application owns the memory; the backend only reads it.
pub const Menu = struct {
    /// Top-level entries, in display order.
    items: []const Item = &.{},
};

pub const Item = union(enum) {
    /// A leaf the user can click.
    command: Command,
    /// A submenu, opened on hover or click.
    submenu: Submenu,
    /// A horizontal line between groups.
    separator,
    /// A checkable entry with state the application owns.
    checkbox: Checkbox,
    /// One of a set of mutually exclusive entries.
    radio: Checkbox,
};

pub const Command = struct {
    /// Stable identifier the application receives in `onMenuCommand`.
    id: []const u8,
    /// Text the user sees. Empty for a role-only item.
    label: []const u8 = "",
    /// Accelerator such as `"Ctrl+Q"` or `"CmdOrCtrl+Shift+P"`.
    accel: []const u8 = "",
    /// A platform-standard action, when this entry is one.
    role: ?Role = null,
    enabled: bool = true,
};

pub const Submenu = struct {
    /// Stable identifier, used for logs and for rebuilding a submenu.
    id: []const u8,
    label: []const u8,
    items: []const Item = &.{},
    enabled: bool = true,
};

pub const Checkbox = struct {
    id: []const u8,
    label: []const u8,
    checked: bool = false,
    accel: []const u8 = "",
    enabled: bool = true,
};

/// Entries every desktop has, with the placement and label its users expect.
pub const Role = enum {
    quit,
    about,
    hide,
    services,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
    minimize,
    zoom,
    close_window,
    fullscreen,
    preferences,
    reload,
    toggle_devtools,
    /// A separator before the window list, as macOS and most desktops have.
    window,
    help,
};

/// A key combination, parsed from `"CmdOrCtrl+Shift+P"`.
///
/// The parsing is deliberately strict: an accelerator that silently fails to
/// bind is worse than a startup error, because the user has no way to tell the
/// difference between "not bound" and "not implemented".
pub const Accelerator = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// The `Cmd` key on macOS, the Windows key on Windows. `CmdOrCtrl` maps
    /// here on macOS and to `ctrl` elsewhere.
    meta: bool = false,
    /// A letter, digit or function-key name such as `"F5"`.
    key: Key = .unknown,

    pub const Key = enum {
        unknown,
        a,
        b,
        c,
        d,
        e,
        f,
        g,
        h,
        i,
        j,
        k,
        l,
        m,
        n,
        o,
        p,
        q,
        r,
        s,
        t,
        u,
        v,
        w,
        x,
        y,
        z,
        digit_0,
        digit_1,
        digit_2,
        digit_3,
        digit_4,
        digit_5,
        digit_6,
        digit_7,
        digit_8,
        digit_9,
        comma,
        period,
        slash,
        backslash,
        semicolon,
        apostrophe,
        bracket_left,
        bracket_right,
        minus,
        equals,
        grave,
        space,
        tab,
        enter,
        escape,
        backspace,
        delete,
        insert,
        home,
        end,
        page_up,
        page_down,
        arrow_up,
        arrow_down,
        arrow_left,
        arrow_right,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
    };

    pub const ParseError = error{ Empty, UnknownKey };

    /// Parses `"CmdOrCtrl+Shift+P"`. The last `+`-separated part is the key;
    /// earlier parts are modifiers. Matching is case-insensitive.
    pub fn parse(text: []const u8) ParseError!Accelerator {
        if (text.len == 0) return error.Empty;
        var self = Accelerator{};
        var it = std.mem.splitScalar(u8, text, '+');
        var parts: [8][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |raw| {
            if (n == parts.len) return error.UnknownKey;
            parts[n] = std.mem.trim(u8, raw, " ");
            n += 1;
        }
        if (n == 0) return error.Empty;

        for (parts[0 .. n - 1]) |mod| {
            if (eqIgnoreCase(mod, "ctrl") or eqIgnoreCase(mod, "control")) {
                self.ctrl = true;
            } else if (eqIgnoreCase(mod, "shift")) {
                self.shift = true;
            } else if (eqIgnoreCase(mod, "alt") or eqIgnoreCase(mod, "option")) {
                self.alt = true;
            } else if (eqIgnoreCase(mod, "cmd") or eqIgnoreCase(mod, "command") or eqIgnoreCase(mod, "super")) {
                self.meta = true;
            } else if (eqIgnoreCase(mod, "cmdorctrl") or eqIgnoreCase(mod, "commandorcontrol")) {
                if (@import("builtin").os.tag == .macos) self.meta = true else self.ctrl = true;
            } else return error.UnknownKey;
        }

        self.key = keyOf(parts[n - 1]) orelse return error.UnknownKey;
        return self;
    }

    /// `true` when every modifier in `self` is down and the key matches.
    pub fn matches(self: Accelerator, ctrl: bool, shift: bool, alt: bool, meta: bool, key: Key) bool {
        return self.key == key and self.ctrl == ctrl and self.shift == shift and
            self.alt == alt and self.meta == meta;
    }

    /// The GTK accelerator string, e.g. `"<Control><Shift>p"`.
    pub fn toGtk(self: Accelerator, buf: []u8) []const u8 {
        // Joined by hand: Zig 0.17 removed the stack-stream helper this used to
        // depend on, and the shape here is simple enough not to need one.
        var parts: [5][]const u8 = undefined;
        var n: usize = 0;
        if (self.ctrl) {
            parts[n] = "<Control>";
            n += 1;
        }
        if (self.shift) {
            parts[n] = "<Shift>";
            n += 1;
        }
        if (self.alt) {
            parts[n] = "<Alt>";
            n += 1;
        }
        if (self.meta) {
            parts[n] = "<Super>";
            n += 1;
        }
        parts[n] = keyName(self.key);
        n += 1;

        var used: usize = 0;
        for (parts[0..n]) |p| {
            if (used + p.len > buf.len) break;
            @memcpy(buf[used..][0..p.len], p);
            used += p.len;
        }
        return buf[0..used];
    }
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn keyOf(raw: []const u8) ?Accelerator.Key {
    if (raw.len == 1) {
        const c = std.ascii.toLower(raw[0]);
        return switch (c) {
            'a'...'z' => @fromBackingInt(@intCast(@backingInt(Accelerator.Key.a) + (c - 'a'))),
            '0'...'9' => @fromBackingInt(@intCast(@backingInt(Accelerator.Key.digit_0) + (c - '0'))),
            ',' => .comma,
            '.' => .period,
            '/' => .slash,
            '\\' => .backslash,
            ';' => .semicolon,
            '\'' => .apostrophe,
            '[' => .bracket_left,
            ']' => .bracket_right,
            '-' => .minus,
            '=' => .equals,
            '`' => .grave,
            else => null,
        };
    }
    const named = .{
        .{ "space", Accelerator.Key.space },
        .{ "tab", Accelerator.Key.tab },
        .{ "enter", Accelerator.Key.enter },
        .{ "return", Accelerator.Key.enter },
        .{ "escape", Accelerator.Key.escape },
        .{ "esc", Accelerator.Key.escape },
        .{ "backspace", Accelerator.Key.backspace },
        .{ "delete", Accelerator.Key.delete },
        .{ "insert", Accelerator.Key.insert },
        .{ "home", Accelerator.Key.home },
        .{ "end", Accelerator.Key.end },
        .{ "pageup", Accelerator.Key.page_up },
        .{ "pagedown", Accelerator.Key.page_down },
        .{ "up", Accelerator.Key.arrow_up },
        .{ "down", Accelerator.Key.arrow_down },
        .{ "left", Accelerator.Key.arrow_left },
        .{ "right", Accelerator.Key.arrow_right },
        .{ "f1", Accelerator.Key.f1 },
        .{ "f2", Accelerator.Key.f2 },
        .{ "f3", Accelerator.Key.f3 },
        .{ "f4", Accelerator.Key.f4 },
        .{ "f5", Accelerator.Key.f5 },
        .{ "f6", Accelerator.Key.f6 },
        .{ "f7", Accelerator.Key.f7 },
        .{ "f8", Accelerator.Key.f8 },
        .{ "f9", Accelerator.Key.f9 },
        .{ "f10", Accelerator.Key.f10 },
        .{ "f11", Accelerator.Key.f11 },
        .{ "f12", Accelerator.Key.f12 },
    };
    inline for (named) |entry| {
        if (eqIgnoreCase(raw, entry[0])) return entry[1];
    }
    return null;
}

const letters = [_][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
};

const digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

fn keyName(key: Accelerator.Key) []const u8 {
    return switch (key) {
        .comma => "comma",
        .period => "period",
        .slash => "slash",
        .backslash => "backslash",
        .semicolon => "semicolon",
        .apostrophe => "apostrophe",
        .bracket_left => "bracketleft",
        .bracket_right => "bracketright",
        .minus => "minus",
        .equals => "equal",
        .grave => "grave",
        .space => "space",
        .tab => "Tab",
        .enter => "Return",
        .escape => "Escape",
        .backspace => "BackSpace",
        .delete => "Delete",
        .insert => "Insert",
        .home => "Home",
        .end => "End",
        .page_up => "Page_Up",
        .page_down => "Page_Down",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .unknown => "unknown",
        else => |k| blk: {
            // Letters and digits are a contiguous run, so the index selects a
            // const name; the tables are comptime, so no allocation happens.
            const n = @backingInt(k);
            const a = @backingInt(Accelerator.Key.a);
            const d = @backingInt(Accelerator.Key.digit_0);
            if (n >= a and n < a + 26) break :blk letters[n - a];
            if (n >= d and n < d + 10) break :blk digits[n - d];
            break :blk "unknown";
        },
    };
}

// ------------------------------------------------------------------ tests

test "parses a modifier chain" {
    const a = try Accelerator.parse("CmdOrCtrl+Shift+P");
    try std.testing.expect(a.meta or a.ctrl);
    try std.testing.expect(a.shift);
    try std.testing.expectEqual(Accelerator.Key.p, a.key);

    const b = try Accelerator.parse("Ctrl+q");
    try std.testing.expect(b.ctrl);
    try std.testing.expect(!b.shift);
    try std.testing.expectEqual(Accelerator.Key.q, b.key);
}

test "parses function keys and named keys" {
    try std.testing.expectEqual(Accelerator.Key.f5, (try Accelerator.parse("F5")).key);
    try std.testing.expectEqual(Accelerator.Key.escape, (try Accelerator.parse("Esc")).key);
    try std.testing.expectEqual(Accelerator.Key.page_down, (try Accelerator.parse("PageDown")).key);
}

test "rejects an unknown key rather than binding nothing" {
    try std.testing.expectError(error.UnknownKey, Accelerator.parse("Ctrl+Banana"));
    try std.testing.expectError(error.Empty, Accelerator.parse(""));
}

test "matches only when every modifier agrees" {
    const a = try Accelerator.parse("Ctrl+Shift+Z");
    try std.testing.expect(a.matches(true, true, false, false, .z));
    // A missing modifier must not match: otherwise Ctrl+Z would fire Ctrl+Shift+Z.
    try std.testing.expect(!a.matches(true, false, false, false, .z));
    try std.testing.expect(!a.matches(true, true, false, false, .y));
}

test "renders a GTK accelerator" {
    const a = try Accelerator.parse("Ctrl+Shift+P");
    var buf: [64]u8 = undefined;
    const text = a.toGtk(&buf);
    try std.testing.expectEqualStrings("<Control><Shift>p", text);
}

test "menu items are values" {
    const items = [_]Item{
        .{ .command = .{ .id = "file.new", .label = "New", .accel = "Ctrl+N" } },
        .separator,
        .{ .submenu = .{ .id = "help", .label = "Help", .items = &.{
            .{ .command = .{ .id = "help.about", .role = .about } },
        } } },
    };
    const menu = Menu{ .items = &items };
    try std.testing.expectEqual(@as(usize, 3), menu.items.len);
    try std.testing.expect(menu.items[1] == .separator);
}

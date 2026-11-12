//! Event values shared by the core, the backends and application code.
//!
//! These are plain values with no allocations: an event can be copied, queued
//! and delivered without a heap operation. Anything larger than a few words
//! lives behind a caller-owned arena in the fields that need it.

const std = @import("std");

/// The system appearance.
pub const Theme = enum {
    light,
    dark,

    /// Parses `"light"` or `"dark"`; other values fall back to light.
    pub fn parse(s: []const u8) Theme {
        return if (std.mem.eql(u8, s, "dark")) .dark else .light;
    }
};

/// Window state as reported by the window manager.
pub const WindowState = enum {
    normal,
    minimized,
    maximized,
    fullscreen,

    pub fn isNormal(self: WindowState) bool {
        return self == .normal;
    }
};

pub const ConsoleLevel = enum {
    log,
    info,
    warn,
    err,
    debug,

    pub fn parse(s: []const u8) ConsoleLevel {
        const map = .{
            .{ "log", ConsoleLevel.log },
            .{ "info", ConsoleLevel.info },
            .{ "warning", ConsoleLevel.warn },
            .{ "error", ConsoleLevel.err },
            .{ "debug", ConsoleLevel.debug },
        };
        inline for (map) |e| {
            if (std.mem.eql(u8, s, e[0])) return e[1];
        }
        return .log;
    }
};

/// A keyboard or pointer key, independent of the platform's key codes.
///
/// Physical keys carry their meaning (a letter, a digit, a function key);
/// their character depends on the layout and modifiers, so typing text is
/// delivered separately as `Input.text`.
pub const Key = enum(u16) {
    unknown = 0,
    // letters
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
    // digits
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
    // punctuation and editing
    space,
    enter,
    tab,
    backspace,
    delete,
    escape,
    insert,
    home,
    end,
    page_up,
    page_down,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    minus,
    equal,
    bracket_left,
    bracket_right,
    backslash,
    semicolon,
    quote,
    comma,
    period,
    slash,
    backquote,
    // modifiers
    shift_left,
    shift_right,
    control_left,
    control_right,
    alt_left,
    alt_right,
    meta_left,
    meta_right,
    caps_lock,
    num_lock,
    // function keys
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
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    // numeric keypad
    kp_add,
    kp_subtract,
    kp_multiply,
    kp_divide,
    kp_decimal,
    kp_enter,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    // media and browser keys
    media_play_pause,
    media_next,
    media_previous,
    media_stop,
    volume_up,
    volume_down,
    volume_mute,
    browser_back,
    browser_forward,
    browser_refresh,
    print_screen,
    scroll_lock,
    pause,

    /// Returns the letter key for an ASCII lowercase letter, if any.
    pub fn fromLetter(ch: u8) ?Key {
        if (ch < 'a' or ch > 'z') return null;
        return @fromBackingInt(@intCast(@backingInt(Key.a) + (ch - 'a')));
    }

    /// Whether this key is a modifier on its own.
    pub fn isModifier(self: Key) bool {
        return switch (self) {
            .shift_left, .shift_right, .control_left, .control_right, .alt_left, .alt_right, .meta_left, .meta_right, .caps_lock, .num_lock => true,
            else => false,
        };
    }
};

/// Keyboard modifiers held during an event.
///
/// `super` is the OS key: Command on macOS, the Windows/Super key elsewhere.
/// `primary` is the accelerator modifier: Command on macOS, Control elsewhere.
pub const Modifiers = packed struct(u8) {
    _reserved: u4 = 0,
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,

    pub const none: Modifiers = .{};

    pub fn primary(self: Modifiers) bool {
        return if (@import("builtin").os.tag == .macos) self.super else self.control;
    }

    pub fn any(self: Modifiers) bool {
        return self.shift or self.control or self.alt or self.super;
    }

    /// Renders the modifiers in the canonical accelerator order: primary,
    /// alt, shift, super.
    pub fn prefix(self: Modifiers, buf: []u8) []const u8 {
        var i: usize = 0;
        const mac = @import("builtin").os.tag == .macos;
        if (self.primary()) {
            const s = if (mac) "Cmd+" else "Ctrl+";
            if (i + s.len > buf.len) return buf[0..i];
            @memcpy(buf[i..][0..s.len], s);
            i += s.len;
        }
        if (self.alt and i + 4 <= buf.len) {
            @memcpy(buf[i..][0..4], "Alt+");
            i += 4;
        }
        if (self.shift and i + 6 <= buf.len) {
            @memcpy(buf[i..][0..6], "Shift+");
            i += 6;
        }
        if (self.super and !mac and i + 6 <= buf.len) {
            @memcpy(buf[i..][0..6], "Super+");
            i += 6;
        }
        return buf[0..i];
    }
};

pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    back = 4,
    forward = 5,
};

/// What an input event is.
///
/// Deliberately a tagged union of copyable values, so a native surface can
/// buffer input without allocating. Text arrives as bytes borrowed from the
/// backend, valid only for the duration of the dispatch.
pub const Input = union(enum) {
    pointer_move: struct {
        x: f32,
        y: f32,
        /// Seconds the pointer has been still before this move, if known.
        hover_time: f32 = 0,
    },
    pointer_down: struct {
        x: f32,
        y: f32,
        button: MouseButton,
        modifiers: Modifiers = .none,
        clicks: u8 = 1,
    },
    pointer_up: struct {
        x: f32,
        y: f32,
        button: MouseButton,
        modifiers: Modifiers = .none,
        clicks: u8 = 1,
    },
    pointer_leave: void,
    wheel: struct {
        x: f32,
        y: f32,
        delta_x: f32,
        delta_y: f32,
        modifiers: Modifiers = .none,
        /// True for touchpad/wheel precision scrolling.
        precise: bool = false,
    },
    key_down: struct {
        key: Key,
        modifiers: Modifiers = .none,
        repeat: bool = false,
    },
    key_up: struct {
        key: Key,
        modifiers: Modifiers = .none,
    },
    /// Committed text from the keyboard or an input method.
    text: struct {
        bytes: []const u8,
    },
    /// An input method's preedit string changed.
    composition_start: void,
    composition_update: struct {
        bytes: []const u8,
        /// Caret position within the preedit in bytes.
        caret: usize = 0,
    },
    composition_end: struct {
        /// The text committed by the input method, if any.
        bytes: []const u8 = "",
    },
    focus_gained: void,
    focus_lost: void,
    /// The pointer entered a draggable file drag over the surface.
    file_drag_over: struct {
        count: usize,
        accepted: *bool,
    },
    file_drop: struct {
        x: f32,
        y: f32,
        count: usize,
    },
    scale_changed: struct {
        scale: f32,
    },
};

test "modifier prefix order" {
    var buf: [32]u8 = undefined;
    const m = Modifiers{ .shift = true, .control = true, .alt = true };
    const s = m.prefix(&buf);
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expectEqualStrings("Cmd+Alt+Shift+", s);
    } else {
        try std.testing.expectEqualStrings("Ctrl+Alt+Shift+", s);
    }
}

test "modifier primary" {
    const m = Modifiers{ .control = true };
    const mac = @import("builtin").os.tag == .macos;
    try std.testing.expectEqual(!mac, m.primary());
}

test "key from letter" {
    try std.testing.expectEqual(Key.a, Key.fromLetter('a').?);
    try std.testing.expectEqual(Key.z, Key.fromLetter('z').?);
    try std.testing.expect(Key.fromLetter('A') == null);
}

test "theme parsing" {
    try std.testing.expectEqual(Theme.dark, Theme.parse("dark"));
    try std.testing.expectEqual(Theme.light, Theme.parse("light"));
    try std.testing.expectEqual(Theme.light, Theme.parse("purple"));
}

test "input union is copyable and small" {
    try std.testing.expect(@sizeOf(Input) <= 64);
    try std.testing.expect(@sizeOf(Modifiers) == 1);
}

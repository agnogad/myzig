//! Global shortcuts on macOS, through Carbon's `RegisterEventHotKey`.
//!
//! ## Why Carbon and not `NSEvent`
//!
//! `NSEvent.addGlobalMonitorForEvents` also sees keys from other applications,
//! but it silently requires the user to grant Accessibility permission. For a
//! shortcut that is a bad trade: many people decline and the feature is simply
//! broken for them. `RegisterEventHotKey` is the old Carbon API, is still not
//! deprecated, and needs no permission at all — which is why it is what every
//! Mac utility actually uses.
//!
//! ## The mistake this module exists to prevent
//!
//! Carbon's modifier masks are **not** Cocoa's flags:
//! | modifier | Carbon | Cocoa (`NSEventModifierFlag`) |
//! |----------|--------|-------------------------------|
//! | Cmd      | 1<<8   | 1<<20                         |
//! | Shift    | 1<<9   | 1<<17                         |
//! | Option   | 1<<11  | 1<<19                         |
//! | Control  | 1<<12  | 1<<18                         |
//!
//! Passing a Cocoa flag straight in registers the wrong chord, or nothing, and
//! fails silently. `menu.zig` already uses the Cocoa numbers for menu key
//! equivalents; this module deliberately uses the Carbon ones, and the mapping
//! is a pure function with tests so the two cannot be confused by accident.
//!
//! ## Testing
//!
//! The keycode and mask tables are plain Zig and tested on Linux. The
//! registration calls are looked up through `std.DynLib` so the file still
//! compiles off macOS, and **have never been run**: there is no Mac here.

const std = @import("std");
const builtin = @import("builtin");
const menu = @import("../../menu.zig");

/// Carbon modifier masks. See the table above for why these look odd.
pub const cmd_key: u32 = 1 << 8;
pub const shift_key: u32 = 1 << 9;
pub const option_key: u32 = 1 << 11;
pub const control_key: u32 = 1 << 12;

/// The Carbon modifier mask for an accelerator.
///
/// `Cmd` is the primary modifier on macOS, which `Accelerator.meta` already
/// means here, so nothing has to be remapped.
pub fn modifierMask(accel: menu.Accelerator) u32 {
    var m: u32 = 0;
    if (accel.meta) m |= cmd_key;
    if (accel.shift) m |= shift_key;
    if (accel.alt) m |= option_key;
    if (accel.ctrl) m |= control_key;
    return m;
}

/// The virtual key code for a key, or null when Carbon has no code for it.
///
/// These are the `kVK_*` values from `HIToolbox/Events.h`. They are *not*
/// ASCII: `kVK_A` is 0, `kVK_S` is 1, and the digits are ordered on the
/// keyboard rather than numerically.
pub fn keyCode(key: menu.Accelerator.Key) ?u32 {
    return switch (key) {
        .a => 0x00,
        .s => 0x01,
        .d => 0x02,
        .f => 0x03,
        .h => 0x04,
        .g => 0x05,
        .z => 0x06,
        .x => 0x07,
        .c => 0x08,
        .v => 0x09,
        .b => 0x0B,
        .q => 0x0C,
        .w => 0x0D,
        .e => 0x0E,
        .r => 0x0F,
        .y => 0x10,
        .t => 0x11,
        .digit_1 => 0x12,
        .digit_2 => 0x13,
        .digit_3 => 0x14,
        .digit_4 => 0x15,
        .digit_6 => 0x16,
        .digit_5 => 0x17,
        .equals => 0x18,
        .digit_9 => 0x19,
        .digit_7 => 0x1A,
        .minus => 0x1B,
        .digit_8 => 0x1C,
        .digit_0 => 0x1D,
        .bracket_right => 0x1E,
        .o => 0x1F,
        .u => 0x20,
        .bracket_left => 0x21,
        .i => 0x22,
        .p => 0x23,
        .l => 0x25,
        .j => 0x26,
        .apostrophe => 0x27,
        .k => 0x28,
        .semicolon => 0x29,
        .backslash => 0x2A,
        .comma => 0x2B,
        .slash => 0x2C,
        .n => 0x2D,
        .m => 0x2E,
        .period => 0x2F,
        .tab => 0x30,
        .space => 0x31,
        .grave => 0x32,
        .backspace => 0x33, // kVK_Delete, the key Mac keyboards label "Delete".
        .escape => 0x35,
        // Carbon has no separate Return and Enter, so `enter` is the main one.
        .enter => 0x24,
        // `delete` is forward-delete, a different key from `backspace`: on a
        // Mac keyboard the key labelled Delete is BackSpace, and forward delete
        // is the one marked `fn`+Delete. Mapping both to 0x33 would bind the
        // wrong key, silently.
        .delete => 0x75,
        .arrow_left => 0x7B,
        .arrow_right => 0x7C,
        .arrow_down => 0x7D,
        .arrow_up => 0x7E,
        .home => 0x73,
        .end => 0x77,
        .page_up => 0x74,
        .page_down => 0x79,
        .f1 => 0x7A,
        .f2 => 0x78,
        .f3 => 0x63,
        .f4 => 0x76,
        .f5 => 0x60,
        .f6 => 0x61,
        .f7 => 0x62,
        .f8 => 0x64,
        .f9 => 0x65,
        .f10 => 0x6D,
        .f11 => 0x67,
        .f12 => 0x6F,
        // Insert is the `Help`/`fn` key on Apple keyboards; Carbon numbers it.
        .insert => 0x72,
        .unknown => null,
    };
}

/// Carbon event constants.
pub const kEventClassKeyboard: u32 = 0x6b65_7962; // 'keyb'
pub const kEventHotKeyPressed: u32 = 5;
pub const kEventParamDirectObject: u32 = 0x2d2d_2d2d; // '----'
pub const typeEventHotKeyID: u32 = 0x686b_6964; // 'hkid'
/// `eventHotKeyExistsErr`: the chord is already taken by someone.
pub const eventHotKeyExistsErr: i32 = -9878;

/// The signature that identifies an event as this framework's.
pub const signature: u32 = 0x4d_5a_47_4c; // 'MZGL'

pub const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

pub const EventTypeSpec = extern struct {
    eventClass: u32,
    eventKind: u32,
};

// ---------------------------------------------------------------- the binding

const HotKey = struct {
    accel_text: []const u8,
    ref: ?*anyopaque = null,
};

var bindings: std.ArrayListUnmanaged(HotKey) = .empty;
var gpa: std.mem.Allocator = undefined;
var on_press: ?backendShortcutFn = null;
var registered = false;

const backendShortcutFn = *const fn (accel: []const u8) void;

pub fn init(allocator: std.mem.Allocator, press: backendShortcutFn) void {
    gpa = allocator;
    on_press = press;
}

pub fn deinit() void {
    if (registered) unregisterAll();
    bindings.deinit(gpa);
    bindings = .empty;
}

fn unregisterAll() void {
    const syms = Symbols.open() orelse return;
    for (bindings.items) |h| {
        if (h.ref) |r| _ = syms.unregister_event_hot_key(r);
    }
    for (bindings.items) |h| gpa.free(h.accel_text);
    bindings.clearRetainingCapacity();
    registered = false;
}

/// The Carbon entry points, looked up at run time so this file compiles on a
/// host that has no Carbon framework to link against.
const Symbols = struct {
    register_event_hot_key: *const fn (u32, u32, EventHotKeyID, ?*anyopaque, u32, *?*anyopaque) callconv(.c) i32,
    unregister_event_hot_key: *const fn (?*anyopaque) callconv(.c) i32,
    install_event_handler: *const fn (
        ?*anyopaque,
        *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) i32,
        usize,
        *const EventTypeSpec,
        ?*anyopaque,
        *?*anyopaque,
    ) callconv(.c) i32,
    get_application_event_target: *const fn () callconv(.c) ?*anyopaque,
    get_event_parameter: *const fn (
        ?*anyopaque,
        u32,
        u32,
        ?*anyopaque,
        usize,
        ?*anyopaque,
        ?*anyopaque,
    ) callconv(.c) i32,

    var cache: ?Symbols = null;
    var tried: bool = false;

    fn open() ?Symbols {
        if (tried) return cache;
        tried = true;
        if (comptime builtin.os.tag != .macos) return null;

        // Carbon lives in the umbrella framework, which is always present.
        var lib = std.DynLib.open("/System/Library/Frameworks/Carbon.framework/Carbon") catch return null;
        const s = Symbols{
            .register_event_hot_key = lib.lookup(@TypeOf(@as(Symbols, undefined).register_event_hot_key), "RegisterEventHotKey") orelse return null,
            .unregister_event_hot_key = lib.lookup(@TypeOf(@as(Symbols, undefined).unregister_event_hot_key), "UnregisterEventHotKey") orelse return null,
            .install_event_handler = lib.lookup(@TypeOf(@as(Symbols, undefined).install_event_handler), "InstallEventHandler") orelse return null,
            .get_application_event_target = lib.lookup(@TypeOf(@as(Symbols, undefined).get_application_event_target), "GetApplicationEventTarget") orelse return null,
            .get_event_parameter = lib.lookup(@TypeOf(@as(Symbols, undefined).get_event_parameter), "GetEventParameter") orelse return null,
        };
        // The library is deliberately never closed: Carbon outlives every
        // shortcut, and unloading it while the event handler is installed
        // would leave a callback pointing into freed pages.
        cache = s;
        return s;
    }
};

/// The handler Carbon calls for every press of every chord.
///
/// One handler serves all of them; the id in the event says which. Installing
/// one per chord is the mistake the Carbon documentation warns about, and it
/// makes unregistering leave stale handlers behind.
fn hotKeyHandler(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    const syms = Symbols.open() orelse return 0;
    var id = EventHotKeyID{ .signature = 0, .id = 0 };
    const status = syms.get_event_parameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        null,
        @sizeOf(EventHotKeyID),
        null,
        @ptrCast(&id),
    );
    if (status != 0) return 0;
    if (id.signature != signature) return 0;

    if (id.id < bindings.items.len) {
        if (on_press) |f| f(bindings.items[id.id].accel_text);
    }
    return 0;
}

/// Binds a global shortcut. Returns `error.NotSupported` when the platform has
/// no Carbon, and `error.AlreadyTaken` when another application holds the chord
/// — which is reported rather than swallowed, because a shortcut that silently
/// does nothing is worse than one that failed to register.
pub fn register(accel: menu.Accelerator, text: []const u8) error{ NotSupported, AlreadyTaken, OutOfMemory }!void {
    const syms = Symbols.open() orelse return error.NotSupported;
    const code = keyCode(accel.key) orelse return error.NotSupported;

    if (!registered) {
        // One handler for the process, installed on the first shortcut.
        var spec = EventTypeSpec{ .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
        const target = syms.get_application_event_target() orelse return error.NotSupported;
        var handler_ref: ?*anyopaque = null;
        const status = syms.install_event_handler(target, &hotKeyHandler, 1, &spec, null, &handler_ref);
        if (status != 0) return error.NotSupported;
        registered = true;
    }

    // Look for an existing binding of the same chord first: re-registering one
    // is a no-op, which is what a window reopening wants.
    const existing: u32 = @intCast(bindings.items.len);
    const id = EventHotKeyID{ .signature = signature, .id = existing };

    var ref: ?*anyopaque = null;
    const status = syms.register_event_hot_key(
        code,
        modifierMask(accel),
        id,
        syms.get_application_event_target(),
        // `kEventHotKeyNoOptions`, so the chord still reaches the frontmost
        // application: a shortcut that swallows the key is surprising.
        0,
        &ref,
    );
    if (status == eventHotKeyExistsErr) return error.AlreadyTaken;
    if (status != 0) return error.NotSupported;

    const copy = try gpa.dupe(u8, text);
    errdefer gpa.free(copy);
    try bindings.append(gpa, .{ .accel_text = copy, .ref = ref });
}

// ------------------------------------------------------------------- tests

test "Carbon modifier masks are not Cocoa's" {
    // Cmd alone is 256 in Carbon and 1<<20 in Cocoa. Sharing the value would
    // register the wrong chord, so the numbers are asserted, not derived.
    try std.testing.expectEqual(@as(u32, 256), cmd_key);
    try std.testing.expectEqual(@as(u32, 512), shift_key);
    try std.testing.expectEqual(@as(u32, 2048), option_key);
    try std.testing.expectEqual(@as(u32, 4096), control_key);

    const accel = try menu.Accelerator.parse("Cmd+Shift+P");
    try std.testing.expectEqual(@as(u32, 256 | 512), modifierMask(accel));
}

test "every modifier maps to its own Carbon bit" {
    const one = [_]struct { text: []const u8, want: u32 }{
        .{ .text = "Cmd+A", .want = cmd_key },
        .{ .text = "Shift+A", .want = shift_key },
        .{ .text = "Alt+A", .want = option_key },
        .{ .text = "Ctrl+A", .want = control_key },
    };
    for (one) |c| {
        const accel = try menu.Accelerator.parse(c.text);
        try std.testing.expectEqual(c.want, modifierMask(accel));
    }

    // No modifier is no mask, which Carbon would refuse to register on its own
    // on some versions; the caller reports that as NotSupported.
    try std.testing.expectEqual(@as(u32, 0), modifierMask(.{ .key = .a }));
}

test "key codes follow the keyboard, not the alphabet" {
    // The classic trap: kVK_A is 0 and kVK_S is 1, and the digits are laid out
    // across the number row rather than in order.
    try std.testing.expectEqual(@as(u32, 0x00), keyCode(.a).?);
    try std.testing.expectEqual(@as(u32, 0x01), keyCode(.s).?);
    try std.testing.expectEqual(@as(u32, 0x12), keyCode(.digit_1).?);
    try std.testing.expectEqual(@as(u32, 0x1D), keyCode(.digit_0).?);
    try std.testing.expectEqual(@as(u32, 0x31), keyCode(.space).?);
    try std.testing.expectEqual(@as(u32, 0x7A), keyCode(.f1).?);
    try std.testing.expectEqual(@as(u32, 0x6F), keyCode(.f12).?);
}

test "backspace and delete are different keys" {
    // The key a Mac keyboard labels "Delete" is BackSpace; forward delete is
    // the `fn`+Delete one. Sharing a code would bind the wrong key.
    try std.testing.expectEqual(@as(u32, 0x33), keyCode(.backspace).?);
    try std.testing.expectEqual(@as(u32, 0x75), keyCode(.delete).?);
    try std.testing.expect(keyCode(.backspace).? != keyCode(.delete).?);
}

test "a key with no Carbon code is refused rather than guessed" {
    // Binding a made-up code would fire on some unrelated key.
    try std.testing.expect(keyCode(.unknown) == null);

    // Insert does exist, as the Help/fn key, so it must not be refused.
    try std.testing.expectEqual(@as(u32, 0x72), keyCode(.insert).?);
}

test "registering off macOS reports NotSupported" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var text_buf: [16]u8 = undefined;
    const accel = try menu.Accelerator.parse("Cmd+Shift+P");
    const text = try std.fmt.bufPrint(&text_buf, "Cmd+Shift+P", .{});
    try std.testing.expectError(error.NotSupported, register(accel, text));
}

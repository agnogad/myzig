//! Global shortcuts on Windows, through `RegisterHotKey`.
//!
//! `RegisterHotKey` binds a chord system-wide and posts `WM_HOTKEY` to the
//! window that registered it, with the binding's id in `wparam`. No hook and no
//! elevated permission are involved, which is why it is the right API here.
//!
//! ## Two things that are easy to get wrong
//!
//! * **`MOD_*` masks are not shifted bits of anything obvious.** `MOD_ALT` is 1,
//!   `MOD_CONTROL` is 2, `MOD_SHIFT` is 4 and `MOD_WIN` is 8. On macOS the same
//!   four are 1<<11, 1<<12, 1<<9 and 1<<8, so a table copied between the two
//!   backends is wrong in every row.
//! * **A key collision is reported through `GetLastError`, not the return
//!   value.** `RegisterHotKey` answers 0 both for "already taken" (error 1409)
//!   and for anything else, so the two are only distinguishable by the error
//!   code. Reporting "already taken" for an unrelated failure would send a
//!   caller looking for another application that is not there.
//!
//! ## Testing
//!
//! Written against the documented Win32 API and **never run**: there is no
//! Windows machine here. The mapping functions are pure and tested on Linux.

const std = @import("std");
const builtin = @import("builtin");
const ffi = @import("ffi.zig");
const menu = @import("../../menu.zig");

/// The `MOD_*` mask for an accelerator.
///
/// `Accelerator.meta` is the `Cmd`-or-`Ctrl` modifier, which on Windows means
/// the Windows key. That is a literal reading of the contract; an application
/// ported from macOS expecting `Cmd+S` to become `Ctrl+S` will instead get
/// `Win+S`, so the mapping is spelled out here rather than assumed.
pub fn modifierMask(accel: menu.Accelerator) u32 {
    var m: u32 = 0;
    if (accel.ctrl) m |= ffi.MOD_CONTROL;
    if (accel.shift) m |= ffi.MOD_SHIFT;
    if (accel.alt) m |= ffi.MOD_ALT;
    if (accel.meta) m |= ffi.MOD_WIN;
    return m;
}

/// The virtual-key code for a key, or null when there is none.
///
/// The letters and digits are their ASCII capitals, which is the one part of
/// Win32 key handling that needs no table.
pub fn virtualKey(key: menu.Accelerator.Key) ?u32 {
    return switch (key) {
        .a => 'A',
        .b => 'B',
        .c => 'C',
        .d => 'D',
        .e => 'E',
        .f => 'F',
        .g => 'G',
        .h => 'H',
        .i => 'I',
        .j => 'J',
        .k => 'K',
        .l => 'L',
        .m => 'M',
        .n => 'N',
        .o => 'O',
        .p => 'P',
        .q => 'Q',
        .r => 'R',
        .s => 'S',
        .t => 'T',
        .u => 'U',
        .v => 'V',
        .w => 'W',
        .x => 'X',
        .y => 'Y',
        .z => 'Z',
        .digit_0 => '0',
        .digit_1 => '1',
        .digit_2 => '2',
        .digit_3 => '3',
        .digit_4 => '4',
        .digit_5 => '5',
        .digit_6 => '6',
        .digit_7 => '7',
        .digit_8 => '8',
        .digit_9 => '9',
        // The punctuation keys have their own codes, spelled out because they
        // are not their ASCII characters: `VK_OEM_1` is `;`, and `VK_OEM_PLUS`
        // is `=`.
        .comma => 0xBC, // VK_OEM_COMMA
        .period => 0xBE, // VK_OEM_PERIOD
        .slash => 0xBF, // VK_OEM_2
        .backslash => 0xDC, // VK_OEM_5
        .semicolon => 0xBA, // VK_OEM_1
        .apostrophe => 0xDE, // VK_OEM_7
        .bracket_left => 0xDB, // VK_OEM_4
        .bracket_right => 0xDD, // VK_OEM_6
        .minus => 0xBD, // VK_OEM_MINUS
        .equals => 0xBB, // VK_OEM_PLUS
        .grave => 0xC0, // VK_OEM_3
        .space => ffi.VK_SPACE,
        .tab => ffi.VK_TAB,
        .enter => ffi.VK_RETURN,
        .escape => ffi.VK_ESCAPE,
        .backspace => ffi.VK_BACK,
        .delete => ffi.VK_DELETE,
        .insert => ffi.VK_INSERT,
        .home => ffi.VK_HOME,
        .end => ffi.VK_END,
        .page_up => ffi.VK_PRIOR,
        .page_down => ffi.VK_NEXT,
        .arrow_up => ffi.VK_UP,
        .arrow_down => ffi.VK_DOWN,
        .arrow_left => ffi.VK_LEFT,
        .arrow_right => ffi.VK_RIGHT,
        // The function keys are contiguous from VK_F1.
        .f1 => ffi.VK_F1,
        .f2 => ffi.VK_F1 + 1,
        .f3 => ffi.VK_F1 + 2,
        .f4 => ffi.VK_F1 + 3,
        .f5 => ffi.VK_F1 + 4,
        .f6 => ffi.VK_F1 + 5,
        .f7 => ffi.VK_F1 + 6,
        .f8 => ffi.VK_F1 + 7,
        .f9 => ffi.VK_F1 + 8,
        .f10 => ffi.VK_F1 + 9,
        .f11 => ffi.VK_F1 + 10,
        .f12 => ffi.VK_F1 + 11,
        .unknown => null,
    };
}

/// The ids are handed out from 1 so 0 stays "no hotkey", which is what Win32
/// uses for the thread-level bindings.
var next_id: c_int = 1;
var bindings: std.ArrayListUnmanaged(Binding) = .empty;
var gpa: std.mem.Allocator = undefined;
var on_press: ?*const fn (accel: []const u8) void = null;

const Binding = struct {
    id: c_int,
    text: []const u8,
};

pub fn init(allocator: std.mem.Allocator, press: *const fn (accel: []const u8) void) void {
    gpa = allocator;
    on_press = press;
}

pub fn deinit() void {
    for (bindings.items) |b| {
        _ = ffi.UnregisterHotKey(null, b.id);
        gpa.free(b.text);
    }
    bindings.deinit(gpa);
    bindings = .empty;
}

/// Binds a global shortcut to the thread's message queue.
///
/// A null window means the binding belongs to the calling thread, so
/// `WM_HOTKEY` arrives in `GetMessageW` for whoever pumps the loop — which is
/// the backend's own message loop.
pub fn register(accel: menu.Accelerator, text: []const u8) error{ NotSupported, AlreadyTaken, OutOfMemory }!void {
    if (comptime builtin.os.tag != .windows) return error.NotSupported;

    const vk = virtualKey(accel.key) orelse return error.NotSupported;

    // A shortcut needs a modifier: Windows refuses a bare key as a global
    // binding, and a global bare key would swallow that key everywhere.
    const mods = modifierMask(accel);
    if (mods == 0) return error.NotSupported;

    const id = next_id;
    if (ffi.RegisterHotKey(null, id, mods | ffi.MOD_NOREPEAT, vk) == 0) {
        const err = ffi.GetLastError();
        if (err == ffi.ERROR_HOTKEY_ALREADY_REGISTERED) return error.AlreadyTaken;
        return error.NotSupported;
    }

    next_id += 1;
    const copy = try gpa.dupe(u8, text);
    errdefer gpa.free(copy);
    try bindings.append(gpa, .{ .id = id, .text = copy });
}

/// Reports a `WM_HOTKEY` to the application. `id` is the low word of `wparam`.
pub fn dispatch(id: c_int) bool {
    for (bindings.items) |b| {
        if (b.id != id) continue;
        if (on_press) |f| f(b.text);
        return true;
    }
    return false;
}

// ------------------------------------------------------------------- tests

test "the Windows modifier masks are their own convention" {
    // Alt is 1, not a high bit; a table copied from macOS would be wrong in
    // every row.
    try std.testing.expectEqual(@as(u32, 1), ffi.MOD_ALT);
    try std.testing.expectEqual(@as(u32, 2), ffi.MOD_CONTROL);
    try std.testing.expectEqual(@as(u32, 4), ffi.MOD_SHIFT);
    try std.testing.expectEqual(@as(u32, 8), ffi.MOD_WIN);

    const accel = try menu.Accelerator.parse("Ctrl+Shift+P");
    try std.testing.expectEqual(@as(u32, 2 | 4), modifierMask(accel));
}

test "letters and digits are their ASCII codes" {
    try std.testing.expectEqual(@as(u32, 'A'), virtualKey(.a).?);
    try std.testing.expectEqual(@as(u32, 'Z'), virtualKey(.z).?);
    try std.testing.expectEqual(@as(u32, '0'), virtualKey(.digit_0).?);
    try std.testing.expectEqual(@as(u32, '9'), virtualKey(.digit_9).?);
}

test "the function keys run contiguously from VK_F1" {
    try std.testing.expectEqual(@as(u32, 0x70), virtualKey(.f1).?);
    try std.testing.expectEqual(@as(u32, 0x70 + 11), virtualKey(.f12).?);
}

test "punctuation is not its ASCII character" {
    // `;` is 0xBA and `=` is 0xBB, not 0x3B and 0x3D.
    try std.testing.expectEqual(@as(u32, 0xBA), virtualKey(.semicolon).?);
    try std.testing.expectEqual(@as(u32, 0xBB), virtualKey(.equals).?);
    try std.testing.expect(virtualKey(.semicolon).? != ';');
    try std.testing.expect(virtualKey(.equals).? != '=');
}

test "a key with no virtual code is refused" {
    try std.testing.expect(virtualKey(.unknown) == null);
}

test "registering off Windows reports NotSupported" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const accel = try menu.Accelerator.parse("Ctrl+Shift+P");
    try std.testing.expectError(error.NotSupported, register(accel, "Ctrl+Shift+P"));
}

test "a shortcut with no modifier is refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // A global binding on a bare key would swallow that key everywhere.
    const accel = try menu.Accelerator.parse("A");
    try std.testing.expectEqual(@as(u32, 0), modifierMask(accel));
}

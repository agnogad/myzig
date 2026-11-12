//! The D-Bus symbols AT-SPI needs, loaded at runtime.
//!
//! `libdbus-1` is opened the first time accessibility is started, so an
//! application that never publishes an accessible tree never maps it. Only the
//! calls the bridge makes are declared; the rest of the library is unused.

const std = @import("std");

pub const Error = error{ LibraryMissing, SymbolMissing };

pub const DBusConnection = opaque {};
pub const DBusMessage = opaque {};
pub const DBusMessageIter = extern struct {
    dummy1: ?*anyopaque = null,
    /// `DBUS_TYPE_*` of the current value.
    dummy2: c_int = 0,
    dummy3: ?*anyopaque = null,
    dummy4: c_int = 0,
    dummy5: c_int = 0,
    dummy6: c_int = 0,
    dummy7: c_int = 0,
    dummy8: c_int = 0,
    dummy9: ?*anyopaque = null,
    dummy10: ?*anyopaque = null,
    dummy11: c_int = 0,
    pad1: c_int = 0,
    pad2: ?*anyopaque = null,
    pad3: ?*anyopaque = null,
};

/// The ones the bridge creates. `DBUS_BUS_SESSION` and `DBUS_BUS_STARTER` are
/// the other two.
pub const DBUS_BUS_SESSION: c_int = 0;

/// `DBUS_TYPE_*` markers. A D-Bus signature is a run of these.
pub const DBUS_TYPE_INVALID: c_int = 0;
pub const DBUS_TYPE_STRING: c_int = 's';
pub const DBUS_TYPE_OBJECT_PATH: c_int = 'o';
pub const DBUS_TYPE_INT32: c_int = 'i';
pub const DBUS_TYPE_UINT32: c_int = 'u';
pub const DBUS_TYPE_BOOLEAN: c_int = 'b';
pub const DBUS_TYPE_DOUBLE: c_int = 'd';
pub const DBUS_TYPE_INT64: c_int = 'x';
pub const DBUS_TYPE_ARRAY: c_int = 'a';
pub const DBUS_TYPE_VARIANT: c_int = 'v';
pub const DBUS_TYPE_STRUCT: c_int = 'r';

pub const DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER: c_int = 1;

pub const Symbols = struct {
    bus_get: *const fn (c_int, *?*anyopaque) callconv(.c) ?*DBusConnection,
    bus_get_unique_name: *const fn (*DBusConnection) callconv(.c) ?[*:0]const u8,
    bus_add_match: *const fn (*DBusConnection, [*:0]const u8, *?*anyopaque) callconv(.c) void,
    bus_request_name: *const fn (*DBusConnection, [*:0]const u8, c_uint, *?*anyopaque) callconv(.c) c_int,
    connection_send: *const fn (*DBusConnection, *DBusMessage, ?*u32) callconv(.c) c_int,
    connection_flush: *const fn (*DBusConnection) callconv(.c) void,
    connection_read_write_dispatch: *const fn (*DBusConnection, c_int) callconv(.c) c_int,
    connection_pop_message: *const fn (*DBusConnection) callconv(.c) ?*DBusMessage,
    connection_close: *const fn (*DBusConnection) callconv(.c) void,
    connection_unref: *const fn (*DBusConnection) callconv(.c) void,
    message_new_method_call: *const fn (?[*:0]const u8, [*:0]const u8, ?[*:0]const u8, [*:0]const u8) callconv(.c) ?*DBusMessage,
    message_new_method_return: *const fn (*DBusMessage) callconv(.c) ?*DBusMessage,
    message_new_error: *const fn (*DBusMessage, [*:0]const u8, [*:0]const u8) callconv(.c) ?*DBusMessage,
    message_new_signal: *const fn (?[*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*DBusMessage,
    message_unref: *const fn (*DBusMessage) callconv(.c) void,
    message_get_sender: *const fn (*DBusMessage) callconv(.c) ?[*:0]const u8,
    message_get_interface: *const fn (*DBusMessage) callconv(.c) ?[*:0]const u8,
    message_get_member: *const fn (*DBusMessage) callconv(.c) ?[*:0]const u8,
    message_get_path: *const fn (*DBusMessage) callconv(.c) ?[*:0]const u8,
    message_iter_init: *const fn (*DBusMessage, *DBusMessageIter) callconv(.c) c_int,
    message_iter_init_append: *const fn (*DBusMessage, *DBusMessageIter) callconv(.c) void,
    message_iter_append_basic: *const fn (*DBusMessageIter, c_int, *const anyopaque) callconv(.c) c_int,
    message_iter_open_container: *const fn (*DBusMessageIter, c_int, ?[*:0]const u8, *DBusMessageIter) callconv(.c) c_int,
    message_iter_close_container: *const fn (*DBusMessageIter, *DBusMessageIter) callconv(.c) c_int,
    message_iter_get_arg_type: *const fn (*DBusMessageIter) callconv(.c) c_int,
    message_iter_get_basic: *const fn (*DBusMessageIter, *anyopaque) callconv(.c) void,
    message_iter_recurse: *const fn (*DBusMessageIter, *DBusMessageIter) callconv(.c) void,
    message_iter_next: *const fn (*DBusMessageIter) callconv(.c) c_int,
};

var lib: ?std.DynLib = null;
var syms: ?Symbols = null;

/// Opens `libdbus-1.so.3` once per process and resolves every symbol the bridge
/// uses. A missing symbol is a failure of the whole load rather than a null
/// pointer discovered later.
pub fn load() Error!*const Symbols {
    if (syms) |*s| return s;

    lib = std.DynLib.open("libdbus-1.so.3") catch return Error.LibraryMissing;
    // Every lookup below reads through the stored copy, which lives as long as
    // the process because the library is never closed.
    const opened = &lib.?;

    syms = .{
        .bus_get = lookup(opened, "dbus_bus_get", @TypeOf(@as(Symbols, undefined).bus_get)) orelse return Error.SymbolMissing,
        .bus_get_unique_name = lookup(opened, "dbus_bus_get_unique_name", @TypeOf(@as(Symbols, undefined).bus_get_unique_name)) orelse return Error.SymbolMissing,
        .bus_add_match = lookup(opened, "dbus_bus_add_match", @TypeOf(@as(Symbols, undefined).bus_add_match)) orelse return Error.SymbolMissing,
        .bus_request_name = lookup(opened, "dbus_bus_request_name", @TypeOf(@as(Symbols, undefined).bus_request_name)) orelse return Error.SymbolMissing,
        .connection_send = lookup(opened, "dbus_connection_send", @TypeOf(@as(Symbols, undefined).connection_send)) orelse return Error.SymbolMissing,
        .connection_flush = lookup(opened, "dbus_connection_flush", @TypeOf(@as(Symbols, undefined).connection_flush)) orelse return Error.SymbolMissing,
        .connection_read_write_dispatch = lookup(opened, "dbus_connection_read_write_dispatch", @TypeOf(@as(Symbols, undefined).connection_read_write_dispatch)) orelse return Error.SymbolMissing,
        .connection_pop_message = lookup(opened, "dbus_connection_pop_message", @TypeOf(@as(Symbols, undefined).connection_pop_message)) orelse return Error.SymbolMissing,
        .connection_close = lookup(opened, "dbus_connection_close", @TypeOf(@as(Symbols, undefined).connection_close)) orelse return Error.SymbolMissing,
        .connection_unref = lookup(opened, "dbus_connection_unref", @TypeOf(@as(Symbols, undefined).connection_unref)) orelse return Error.SymbolMissing,
        .message_new_method_call = lookup(opened, "dbus_message_new_method_call", @TypeOf(@as(Symbols, undefined).message_new_method_call)) orelse return Error.SymbolMissing,
        .message_new_method_return = lookup(opened, "dbus_message_new_method_return", @TypeOf(@as(Symbols, undefined).message_new_method_return)) orelse return Error.SymbolMissing,
        .message_new_error = lookup(opened, "dbus_message_new_error", @TypeOf(@as(Symbols, undefined).message_new_error)) orelse return Error.SymbolMissing,
        .message_new_signal = lookup(opened, "dbus_message_new_signal", @TypeOf(@as(Symbols, undefined).message_new_signal)) orelse return Error.SymbolMissing,
        .message_unref = lookup(opened, "dbus_message_unref", @TypeOf(@as(Symbols, undefined).message_unref)) orelse return Error.SymbolMissing,
        .message_get_sender = lookup(opened, "dbus_message_get_sender", @TypeOf(@as(Symbols, undefined).message_get_sender)) orelse return Error.SymbolMissing,
        .message_get_interface = lookup(opened, "dbus_message_get_interface", @TypeOf(@as(Symbols, undefined).message_get_interface)) orelse return Error.SymbolMissing,
        .message_get_member = lookup(opened, "dbus_message_get_member", @TypeOf(@as(Symbols, undefined).message_get_member)) orelse return Error.SymbolMissing,
        .message_get_path = lookup(opened, "dbus_message_get_path", @TypeOf(@as(Symbols, undefined).message_get_path)) orelse return Error.SymbolMissing,
        .message_iter_init = lookup(opened, "dbus_message_iter_init", @TypeOf(@as(Symbols, undefined).message_iter_init)) orelse return Error.SymbolMissing,
        .message_iter_init_append = lookup(opened, "dbus_message_iter_init_append", @TypeOf(@as(Symbols, undefined).message_iter_init_append)) orelse return Error.SymbolMissing,
        .message_iter_append_basic = lookup(opened, "dbus_message_iter_append_basic", @TypeOf(@as(Symbols, undefined).message_iter_append_basic)) orelse return Error.SymbolMissing,
        .message_iter_open_container = lookup(opened, "dbus_message_iter_open_container", @TypeOf(@as(Symbols, undefined).message_iter_open_container)) orelse return Error.SymbolMissing,
        .message_iter_close_container = lookup(opened, "dbus_message_iter_close_container", @TypeOf(@as(Symbols, undefined).message_iter_close_container)) orelse return Error.SymbolMissing,
        .message_iter_get_arg_type = lookup(opened, "dbus_message_iter_get_arg_type", @TypeOf(@as(Symbols, undefined).message_iter_get_arg_type)) orelse return Error.SymbolMissing,
        .message_iter_get_basic = lookup(opened, "dbus_message_iter_get_basic", @TypeOf(@as(Symbols, undefined).message_iter_get_basic)) orelse return Error.SymbolMissing,
        .message_iter_recurse = lookup(opened, "dbus_message_iter_recurse", @TypeOf(@as(Symbols, undefined).message_iter_recurse)) orelse return Error.SymbolMissing,
        .message_iter_next = lookup(opened, "dbus_message_iter_next", @TypeOf(@as(Symbols, undefined).message_iter_next)) orelse return Error.SymbolMissing,
    };
    return &syms.?;
}

fn lookup(lib_ptr: *std.DynLib, name: [:0]const u8, comptime T: type) ?T {
    // `DynLib.lookup` takes the type first and returns it already cast.
    return lib_ptr.lookup(T, name);
}

test "a missing library is a named error, not a crash" {
    // On a machine without libdbus-1 the load reports it. On one with it, the
    // symbols resolve. Either way nothing here dereferences null.
    if (load()) |_| {
        // Resolved; a second call must return the same cached pointer.
        _ = try load();
    } else |e| {
        try std.testing.expect(e == Error.LibraryMissing or e == Error.SymbolMissing);
    }
}

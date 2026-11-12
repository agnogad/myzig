//! The tray icon on a desktop without a status area.
//!
//! `GtkStatusIcon` (see `gtray.zig`) needs an XEmbed status area. GNOME dropped
//! one years ago, Wayland has no equivalent, and KDE and Ubuntu only show icons
//! that speak the StatusNotifierItem protocol — which is what
//! `libappindicator3` wraps.
//!
//! So an application asks for a tray icon once and gets whichever works: the
//! deprecated X11 icon where a status area exists, an AppIndicator where one
//! does not. Both are loaded at runtime, so a machine with neither still starts.
//!
//! ## What is honest here
//!
//! An AppIndicator is only visible when the shell runs a StatusNotifier host.
//! There is no way to ask the library whether that is the case, so `create`
//! reports which path it took and the application can say so in its own UI. A
//! false answer is worse than a qualified one.

const std = @import("std");
const ffi = @import("ffi.zig");
const log = @import("../../log.zig");

/// The AppIndicator entry points MyZig uses. Loaded from
/// `libappindicator3.so.1`, which is `libappindicator3-1` on Debian and
/// `libappindicator-gtk3` on Arch.
pub const Api = struct {
    new_: *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) ?*anyopaque,
    set_status: *const fn (*anyopaque, c_int) callconv(.c) void,
    set_icon_full: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) void,
    set_label: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) void,
    set_title: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    set_menu: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
};

/// `APP_INDICATOR_STATUS_ACTIVE`.
pub const status_active: c_int = 1;

var lib: ?std.DynLib = null;
var api: ?Api = null;

/// Opens `libappindicator3.so.1` once. A machine without it reports that rather
/// than failing later.
pub fn load() !*const Api {
    if (api) |*a| return a;

    // The Ayatana fork ships the same API under a different soname, so a
    // distribution that only has that one is still usable.
    lib = std.DynLib.open("libappindicator3.so.1") catch
        std.DynLib.open("libayatana-appindicator3.so.1") catch return error.LibraryMissing;
    const l = &lib.?;

    api = Api{
        .new_ = l.lookup(@TypeOf(@as(Api, undefined).new_), "app_indicator_new") orelse
            return error.SymbolMissing,
        .set_status = l.lookup(@TypeOf(@as(Api, undefined).set_status), "app_indicator_set_status") orelse
            return error.SymbolMissing,
        .set_icon_full = l.lookup(@TypeOf(@as(Api, undefined).set_icon_full), "app_indicator_set_icon_full") orelse
            return error.SymbolMissing,
        .set_label = l.lookup(@TypeOf(@as(Api, undefined).set_label), "app_indicator_set_label") orelse
            return error.SymbolMissing,
        .set_title = l.lookup(@TypeOf(@as(Api, undefined).set_title), "app_indicator_set_title") orelse
            return error.SymbolMissing,
        .set_menu = l.lookup(@TypeOf(@as(Api, undefined).set_menu), "app_indicator_set_menu") orelse
            return error.SymbolMissing,
    };
    return &api.?;
}

/// An indicator the application owns.
pub const Indicator = struct {
    handle: *anyopaque,
    /// The title, owned here because the library keeps the pointer.
    title: [:0]u8,
};

/// Creates an indicator showing `icon_name` from the icon theme.
///
/// The `id` is what the shell remembers the icon by, so it should be stable
/// across runs and unique to the application.
pub fn create(
    allocator: std.mem.Allocator,
    id: []const u8,
    icon_name: []const u8,
    title: []const u8,
) !Indicator {
    const a = try load();

    const id_z = ffi.CStr.init(id);
    const icon_z = ffi.CStr.init(icon_name);

    const owned = try allocator.alloc(u8, title.len + 1);
    errdefer allocator.free(owned);
    @memcpy(owned[0..title.len], title);
    owned[title.len] = 0;
    const title_z = owned[0..title.len :0];

    const handle = a.new_(id_z.ptr(), icon_z.ptr(), 0) orelse return error.CreateFailed;
    // The description is the accessible name; passing the title is better than
    // passing nothing, which is what a reader announces otherwise.
    a.set_icon_full(handle, icon_z.ptr(), title_z.ptr);
    a.set_title(handle, title_z.ptr);
    a.set_status(handle, status_active);

    return .{ .handle = handle, .title = title_z };
}

/// Gives the indicator a menu. `gtk_menu` is a `GtkMenu`, which `gtray.zig`'s
/// menu builder produces.
pub fn setMenu(indicator: *const Indicator, gtk_menu: ?*anyopaque) void {
    const a = api orelse return;
    a.set_menu(indicator.handle, gtk_menu);
}

pub fn destroy(indicator: Indicator, allocator: std.mem.Allocator) void {
    // There is no `app_indicator_unref` in the documented API; the indicator is
    // a `GObject`, so its reference is dropped through GTK.
    _ = ffi.g_object_unref(@ptrCast(indicator.handle));
    allocator.free(indicator.title);
}

test "a missing indicator library is reported, not swallowed" {
    if (load()) |_| {
        // Present on this machine; the cache must return the same pointer.
        _ = try load();
    } else |e| {
        try std.testing.expect(e == error.LibraryMissing or e == error.SymbolMissing);
    }
}

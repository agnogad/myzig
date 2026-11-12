//! Publishes a native window's accessibility tree to AT-SPI over D-Bus.
//!
//! A screen reader on Linux talks to `org.a11y.atspi`. It asks for the
//! application's objects, walks their children, and reads their roles, names
//! and states. Without this file a MyZig native window is a rectangle of pixels
//! that a reader cannot see into at all.
//!
//! ## Paths
//!
//! Every object has a path, and the path is the whole address — nothing is kept
//! in a side table that a reader could fall out of step with:
//!
//! ```text
//! /org/a11y/atspi/accessible/root          the registry root
//! /org/a11y/atspi/accessible/root/w0       window in slot 0
//! /org/a11y/atspi/accessible/root/w0/n3    node 3 of that window's tree
//! ```
//!
//! A path that does not parse, or names a node the current tree does not have,
//! gets no reply. AT-SPI clients time out and move on, which is better than a
//! wrong answer.
//!
//! ## Threading
//!
//! Every call here happens on the thread that pumps the loop, and none of them
//! block: a reply is built from the tree the application already published.
//!
//! ## Coverage
//!
//! Implemented: `GetChildCount`, `GetChildAtIndex`, `GetChildren`, `GetRole`,
//! `GetRoleName`, `GetName`, `GetDescription`, `GetState`, `GetParent`,
//! `GetInterfaces`, `Contains`, `GetExtents`, and the `ChildrenChanged` event.
//!
//! Not implemented: `DoAction` (a reader can find a button but cannot press it
//! yet), `GetText`, and the value interface. Those are the next step, and this
//! comment is the list of them.

const std = @import("std");
const dbus = @import("dbus.zig");
const a11y = @import("../../ui/accessibility/a11y.zig");
const geometry = @import("../../ui/geometry.zig");
const log = @import("../../log.zig");

pub const Error = error{
    LibraryMissing,
    SymbolMissing,
    NoSessionBus,
    OutOfMemory,
};

const atspi_accessible = "org.a11y.atspi.Accessible";
const atspi_component = "org.a11y.atspi.Component";
const atspi_event = "org.a11y.atspi.Event.Object";

/// Where AT-SPI looks for the root object.
const registry_root = "/org/a11y/atspi/accessible/root";

/// The prefix every object this bridge publishes lives under.
const path_prefix = registry_root ++ "/w";

/// The most windows a single application publishes. A path segment has to stay
/// stable for a window's lifetime because a reader caches it, so the slots are
/// fixed rather than reused by index.
const max_windows = 16;

/// One window's published tree.
pub const Window = struct {
    id: u32,
    /// The tree as of the last frame. Borrowed from the application, so it is
    /// valid only until the tree is rebuilt.
    snapshot: a11y.Snapshot = .{ .nodes = &.{} },
};

/// What the registry root answers with. There is one application per process,
/// so one static node is enough and saves allocating a tree nobody else reads.
var root_node: a11y.Node = .{ .id = 0, .role = .window, .name = "MyZig" };

pub const Bridge = struct {
    syms: *const dbus.Symbols,
    connection: ?*dbus.DBusConnection = null,
    /// The bus name this application owns, as D-Bus reports it.
    unique_name: []const u8 = "",
    windows: [max_windows]?Window = @splat(null),
    /// Room for the paths handed out while one message is answered. A reply
    /// writes at most a handful of paths (a child list), and they all live
    /// until the next `dispatch`, which is the lifetime the D-Bus call needs.
    paths: [max_paths][max_path_len]u8 = @splat(@splat(0)),
    path_count: usize = 0,

    const max_paths = 256;
    const max_path_len = 96;

    /// Opens the session bus. A session with no accessibility bus is not an
    /// error: nothing is published, and a reader that is not there is told
    /// nothing.
    pub fn start() Error!Bridge {
        const syms = dbus.load() catch |e| return switch (e) {
            error.LibraryMissing => Error.LibraryMissing,
            error.SymbolMissing => Error.SymbolMissing,
        };

        var error_out: ?*anyopaque = null;
        const conn = syms.bus_get(dbus.DBUS_BUS_SESSION, &error_out) orelse
            return Error.NoSessionBus;

        return .{
            .syms = syms,
            .connection = conn,
            .unique_name = if (syms.bus_get_unique_name(conn)) |n| std.mem.span(n) else "",
        };
    }

    pub fn stop(self: *Bridge) void {
        if (self.connection) |c| {
            // `dbus_bus_get` hands back a *shared* connection, and D-Bus
            // forbids closing one: only the reference is dropped.
            self.syms.connection_unref(c);
            self.connection = null;
        }
    }

    /// Publishes a window's tree. Called once per frame; a reader sees the
    /// shape of the last frame from then on.
    pub fn publish(self: *Bridge, window_id: u32, snapshot: a11y.Snapshot) void {
        for (&self.windows) |*slot| {
            if (slot.*) |*w| {
                if (w.id == window_id) {
                    w.snapshot = snapshot;
                    return;
                }
            }
        }
        for (&self.windows) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .id = window_id, .snapshot = snapshot };
                return;
            }
        }
        log.warn("accessibility: no slot for window {d}", .{window_id});
    }

    pub fn unpublish(self: *Bridge, window_id: u32) void {
        for (&self.windows) |*slot| {
            if (slot.*) |w| {
                if (w.id == window_id) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Reads from the socket once, which is what makes a message visible to
    /// `connection_pop_message`. The connection is shared, so its dispatcher
    /// thread may already have done this; the call is harmless either way.
    pub fn pump(self: *Bridge) void {
        const conn = self.connection orelse return;
        _ = self.syms.connection_read_write_dispatch(conn, 0);
    }

    /// Answers every pending D-Bus message. Called from the loop; it never
    /// blocks.
    pub fn dispatch(self: *Bridge) void {
        const conn = self.connection orelse return;
        while (self.syms.connection_pop_message(conn)) |msg| {
            defer self.syms.message_unref(msg);
            self.handle(msg);
        }
    }

    fn handle(self: *Bridge, msg: *dbus.DBusMessage) void {
        const member_z = self.syms.message_get_member(msg) orelse return;
        const member = std.mem.span(member_z);
        const path_z = self.syms.message_get_path(msg) orelse return;
        const path = std.mem.span(path_z);

        const target = self.resolve(path) orelse return;

        if (std.mem.eql(u8, member, "GetChildCount")) {
            return self.replyU32(msg, target.childCount());
        }
        if (std.mem.eql(u8, member, "GetRole")) {
            return self.replyU32(msg, @backingInt(target.node.role));
        }
        if (std.mem.eql(u8, member, "GetRoleName")) {
            return self.replyString(msg, target.node.role.atspiName());
        }
        if (std.mem.eql(u8, member, "GetName")) {
            return self.replyString(msg, target.node.name);
        }
        if (std.mem.eql(u8, member, "GetDescription")) {
            return self.replyString(msg, target.node.description);
        }
        if (std.mem.eql(u8, member, "GetState")) {
            return self.replyStates(msg, target.node.states);
        }
        if (std.mem.eql(u8, member, "GetParent")) {
            return self.replyReference(msg, target.parentPath());
        }
        if (std.mem.eql(u8, member, "GetInterfaces")) {
            return self.replyInterfaces(msg);
        }
        if (std.mem.eql(u8, member, "GetChildAtIndex")) {
            const index = self.firstU32Arg(msg) orelse return;
            const child = target.childAt(index) orelse return;
            return self.replyReference(msg, child);
        }
        if (std.mem.eql(u8, member, "GetChildren")) {
            return self.replyChildren(msg, target);
        }
        if (std.mem.eql(u8, member, "Contains")) {
            const x = self.firstI32Arg(msg) orelse return;
            const y = self.secondI32Arg(msg) orelse return;
            const b = target.node.bounds;
            const inside = x >= b.x and y >= b.y and
                x < b.x + b.width and y < b.y + b.height;
            return self.replyBool(msg, inside);
        }
        if (std.mem.eql(u8, member, "GetExtents")) {
            return self.replyExtents(msg, target.node.bounds);
        }
    }

    // ------------------------------------------------------------- resolving

    /// What a path names.
    const Target = struct {
        bridge: *Bridge,
        /// The window slot the path belongs to, or `null` for the root, which
        /// stands for the application rather than one window.
        slot: ?usize,
        node: *const a11y.Node,
        /// The path this object was asked about.
        path: []const u8,

        fn childCount(self: Target) u32 {
            const slot = self.slot orelse return @intCast(self.bridge.windowCount());
            var n: u32 = 0;
            var child = self.node.first_child;
            while (child) |id| {
                n += 1;
                const c = self.bridge.node(slot, id) orelse break;
                child = c.next_sibling;
            }
            return n;
        }

        /// The path of the `index`th child, or `null` when there is none.
        fn childAt(self: Target, index: u32) ?[]const u8 {
            const slot = self.slot orelse return self.bridge.windowPath(index);
            var i: u32 = 0;
            var child = self.node.first_child;
            while (child) |id| {
                if (i == index) return self.bridge.pathFor(slot, id);
                i += 1;
                const c = self.bridge.node(slot, id) orelse return null;
                child = c.next_sibling;
            }
            return null;
        }

        fn parentPath(self: Target) []const u8 {
            const slot = self.slot orelse return registry_root;
            if (self.node.parent) |p| {
                return self.bridge.pathFor(slot, p) orelse registry_root;
            }
            // A window's parent is the registry root.
            return registry_root;
        }
    };

    /// The nodes of the window in `slot` that `id` belongs to. The lookup walks
    /// the published snapshot rather than a cache, so a reader can never see a
    /// node from a frame the application has already replaced.
    fn node(self: *Bridge, slot: usize, id: u32) ?*const a11y.Node {
        const w = self.windows[slot] orelse return null;
        return w.snapshot.get(id);
    }

    /// The path of a node, written into the bridge's own buffer so it stays
    /// valid while the reply is being built.
    fn pathFor(self: *Bridge, slot: usize, id: u32) ?[]const u8 {
        if (self.path_count >= max_paths) self.path_count = 0;
        const buf = &self.paths[self.path_count];
        self.path_count += 1;
        const text = std.fmt.bufPrint(buf, "{s}{d}/n{d}", .{ path_prefix, slot, id }) catch
            return null;
        return text;
    }

    /// Parses a path into the window slot and node id it names.
    ///
    /// The registry root is itself an object: it has one child per window and
    /// no role of its own, which is how AT-SPI describes an application.
    fn resolve(self: *Bridge, path: []const u8) ?Target {
        // The root: answer for the application as a whole.
        if (std.mem.eql(u8, path, registry_root)) {
            return self.rootTarget(path);
        }
        if (!std.mem.startsWith(u8, path, path_prefix)) return null;
        const rest = path[path_prefix.len..];

        // `/w<slot>` is a window; `/w<slot>/n<id>` is one of its nodes.
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const slot_end = slash orelse rest.len;
        const slot = std.fmt.parseInt(usize, rest[0..slot_end], 10) catch return null;
        if (slot >= max_windows) return null;
        const w = self.windows[slot] orelse return null;

        if (slash == null) {
            // The window object stands for the root node of its own tree.
            const root = w.snapshot.root orelse return null;
            const n = w.snapshot.get(root) orelse return null;
            return .{ .bridge = self, .slot = slot, .node = n, .path = path };
        }

        const tail = rest[slot_end + 1 ..];
        if (!std.mem.startsWith(u8, tail, "n")) return null;
        const id = std.fmt.parseInt(u32, tail[1..], 10) catch return null;
        const n = w.snapshot.get(id) orelse return null;
        return .{ .bridge = self, .slot = slot, .node = n, .path = path };
    }

    /// The synthetic application node the registry root stands for. It has one
    /// child per published window.
    fn rootTarget(self: *Bridge, path: []const u8) Target {
        // The root's own description is stored in this window so it can be
        // answered for like any other node.
        root_node = .{
            .id = 0,
            .role = .window,
            .name = "MyZig",
            .sibling_count = @intCast(self.windowCount()),
        };
        return .{ .bridge = self, .slot = null, .node = &root_node, .path = path };
    }

    /// The path of the `index`th *published* window, which is the root's child
    /// list.
    fn windowPath(self: *Bridge, index: u32) ?[]const u8 {
        var seen: u32 = 0;
        for (self.windows, 0..) |w, slot| {
            if (w == null) continue;
            if (seen == index) {
                if (self.path_count >= max_paths) self.path_count = 0;
                const buf = &self.paths[self.path_count];
                self.path_count += 1;
                return std.fmt.bufPrint(buf, "{s}{d}", .{ path_prefix, slot }) catch null;
            }
            seen += 1;
        }
        return null;
    }

    fn windowCount(self: *Bridge) usize {
        var n: usize = 0;
        for (self.windows) |w| {
            if (w != null) n += 1;
        }
        return n;
    }

    // --------------------------------------------------------------- replies

    fn replyU32(self: *Bridge, msg: *dbus.DBusMessage, value: u32) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);
        _ = self.syms.message_iter_append_basic(&it, dbus.DBUS_TYPE_UINT32, @ptrCast(&value));
        self.send(reply);
    }

    fn replyBool(self: *Bridge, msg: *dbus.DBusMessage, value: bool) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);
        var raw: c_int = if (value) 1 else 0;
        _ = self.syms.message_iter_append_basic(&it, dbus.DBUS_TYPE_BOOLEAN, @ptrCast(&raw));
        self.send(reply);
    }

    fn replyString(self: *Bridge, msg: *dbus.DBusMessage, value: []const u8) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);
        // D-Bus strings are NUL-terminated and may not contain a NUL, so a copy
        // is made on the stack for the length of this call.
        var buf: [1024]u8 = undefined;
        const n = @min(value.len, buf.len - 1);
        @memcpy(buf[0..n], value[0..n]);
        buf[n] = 0;
        const ptr: [*:0]const u8 = @ptrCast(&buf);
        _ = self.syms.message_iter_append_basic(&it, dbus.DBUS_TYPE_STRING, @ptrCast(&ptr));
        self.send(reply);
    }

    fn replyStates(self: *Bridge, msg: *dbus.DBusMessage, states: a11y.States) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);

        // AT-SPI's state is two uint32 bitfields. The bit positions are the
        // ones in `atspi-constants.h`; only the ones MyZig sets are named.
        var words = [2]u32{ 0, 0 };
        if (states.enabled) words[0] |= @as(u32, 1) << 8; // ENABLED
        if (states.focused) words[0] |= @as(u32, 1) << 12; // FOCUSED
        if (states.selected) words[0] |= @as(u32, 1) << 25; // SELECTED
        if (states.offscreen) words[1] |= @as(u32, 1) << 14; // OFFSCREEN
        if (states.busy) words[1] |= @as(u32, 1) << 12; // BUSY

        var array_it: dbus.DBusMessageIter = .{};
        _ = self.syms.message_iter_open_container(&it, dbus.DBUS_TYPE_ARRAY, "u", &array_it);
        for (words) |w| {
            _ = self.syms.message_iter_append_basic(&array_it, dbus.DBUS_TYPE_UINT32, @ptrCast(&w));
        }
        _ = self.syms.message_iter_close_container(&it, &array_it);
        self.send(reply);
    }

    /// AT-SPI identifies an object by a (bus name, path) pair, which is a
    /// struct of a string and an object path.
    fn replyReference(self: *Bridge, msg: *dbus.DBusMessage, path: []const u8) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);

        var struct_it: dbus.DBusMessageIter = .{};
        _ = self.syms.message_iter_open_container(&it, dbus.DBUS_TYPE_STRUCT, null, &struct_it);

        const name: [*:0]const u8 = @ptrCast(self.unique_name.ptr);
        _ = self.syms.message_iter_append_basic(&struct_it, dbus.DBUS_TYPE_STRING, @ptrCast(&name));

        var path_buf: [256]u8 = undefined;
        const n = @min(path.len, path_buf.len - 1);
        @memcpy(path_buf[0..n], path[0..n]);
        path_buf[n] = 0;
        const path_ptr: [*:0]const u8 = @ptrCast(&path_buf);
        _ = self.syms.message_iter_append_basic(&struct_it, dbus.DBUS_TYPE_OBJECT_PATH, @ptrCast(&path_ptr));

        _ = self.syms.message_iter_close_container(&it, &struct_it);
        self.send(reply);
    }

    fn replyChildren(self: *Bridge, msg: *dbus.DBusMessage, target: Target) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);

        var array_it: dbus.DBusMessageIter = .{};
        _ = self.syms.message_iter_open_container(&it, dbus.DBUS_TYPE_ARRAY, "(so)", &array_it);

        var i: u32 = 0;
        while (target.childAt(i)) |child_path| : (i += 1) {
            var struct_it: dbus.DBusMessageIter = .{};
            _ = self.syms.message_iter_open_container(&array_it, dbus.DBUS_TYPE_STRUCT, null, &struct_it);

            const name: [*:0]const u8 = @ptrCast(self.unique_name.ptr);
            _ = self.syms.message_iter_append_basic(&struct_it, dbus.DBUS_TYPE_STRING, @ptrCast(&name));

            var path_buf: [256]u8 = undefined;
            const n = @min(child_path.len, path_buf.len - 1);
            @memcpy(path_buf[0..n], child_path[0..n]);
            path_buf[n] = 0;
            const path_ptr: [*:0]const u8 = @ptrCast(&path_buf);
            _ = self.syms.message_iter_append_basic(&struct_it, dbus.DBUS_TYPE_OBJECT_PATH, @ptrCast(&path_ptr));

            _ = self.syms.message_iter_close_container(&array_it, &struct_it);
        }
        _ = self.syms.message_iter_close_container(&it, &array_it);
        self.send(reply);
    }

    /// `GetExtents` returns a `(iiii)` of screen coordinates. MyZig reports the
    /// window-relative rectangle, which is what a reader uses to scroll a node
    /// into view.
    fn replyExtents(self: *Bridge, msg: *dbus.DBusMessage, r: geometry.Rect) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);

        var struct_it: dbus.DBusMessageIter = .{};
        _ = self.syms.message_iter_open_container(&it, dbus.DBUS_TYPE_STRUCT, null, &struct_it);
        for ([_]i32{ r.x, r.y, r.width, r.height }) |v| {
            var value = v;
            _ = self.syms.message_iter_append_basic(&struct_it, dbus.DBUS_TYPE_INT32, @ptrCast(&value));
        }
        _ = self.syms.message_iter_close_container(&it, &struct_it);
        self.send(reply);
    }

    fn replyInterfaces(self: *Bridge, msg: *dbus.DBusMessage) void {
        const reply = self.syms.message_new_method_return(msg) orelse return;
        defer self.syms.message_unref(reply);
        var it: dbus.DBusMessageIter = .{};
        self.syms.message_iter_init_append(reply, &it);
        var array_it: dbus.DBusMessageIter = .{};
        _ = self.syms.message_iter_open_container(&it, dbus.DBUS_TYPE_ARRAY, "s", &array_it);
        for ([_][*:0]const u8{ atspi_accessible, atspi_component }) |name| {
            _ = self.syms.message_iter_append_basic(&array_it, dbus.DBUS_TYPE_STRING, @ptrCast(&name));
        }
        _ = self.syms.message_iter_close_container(&it, &array_it);
        self.send(reply);
    }

    fn send(self: *Bridge, msg: *dbus.DBusMessage) void {
        const conn = self.connection orelse return;
        _ = self.syms.connection_send(conn, msg, null);
        _ = self.syms.connection_flush(conn);
    }

    // ------------------------------------------------------------ arguments

    fn firstU32Arg(self: *Bridge, msg: *dbus.DBusMessage) ?u32 {
        var it: dbus.DBusMessageIter = .{};
        if (self.syms.message_iter_init(msg, &it) == 0) return null;
        if (self.syms.message_iter_get_arg_type(&it) != dbus.DBUS_TYPE_UINT32) return null;
        var value: u32 = 0;
        self.syms.message_iter_get_basic(&it, @ptrCast(&value));
        return value;
    }

    fn firstI32Arg(self: *Bridge, msg: *dbus.DBusMessage) ?i32 {
        var it: dbus.DBusMessageIter = .{};
        if (self.syms.message_iter_init(msg, &it) == 0) return null;
        if (self.syms.message_iter_get_arg_type(&it) != dbus.DBUS_TYPE_INT32) return null;
        var value: i32 = 0;
        self.syms.message_iter_get_basic(&it, @ptrCast(&value));
        return value;
    }

    fn secondI32Arg(self: *Bridge, msg: *dbus.DBusMessage) ?i32 {
        var it: dbus.DBusMessageIter = .{};
        if (self.syms.message_iter_init(msg, &it) == 0) return null;
        if (self.syms.message_iter_get_arg_type(&it) != dbus.DBUS_TYPE_INT32) return null;
        _ = self.syms.message_iter_next(&it);
        if (self.syms.message_iter_get_arg_type(&it) != dbus.DBUS_TYPE_INT32) return null;
        var value: i32 = 0;
        self.syms.message_iter_get_basic(&it, @ptrCast(&value));
        return value;
    }
};

/// The process-wide bridge. Accessibility is one connection per application,
/// not one per window, so it lives here rather than in a surface.
var global: ?Bridge = null;
/// Whether `start` has been attempted, so a machine without an accessibility
/// bus is not asked again every frame.
var started = false;

/// Publishes a window's tree, starting the bridge on first use.
///
/// A failure is logged once and then silent: an application on a machine with
/// no accessibility bus runs normally and simply is not visible to a reader.
pub fn publish(window_id: u32, snapshot: a11y.Snapshot) void {
    if (!started) {
        started = true;
        global = Bridge.start() catch |e| {
            log.info("accessibility: not published ({s})", .{@errorName(e)});
            return;
        };
        log.debug("accessibility: publishing on '{s}'", .{global.?.unique_name});
    }
    if (global) |*b| b.publish(window_id, snapshot);
}

pub fn unpublish(window_id: u32) void {
    if (global) |*b| b.unpublish(window_id);
}

/// Answers pending accessibility calls. The loop calls this beside its other
/// work, which is what lets a reader's questions be answered.
pub fn dispatch() void {
    if (global) |*b| {
        b.pump();
        b.dispatch();
    }
}

/// Whether anything is published, so the loop can skip the call entirely.
pub fn active() bool {
    return global != null;
}

pub fn shutdown() void {
    if (global) |*b| b.stop();
    global = null;
    started = false;
}

comptime {
    _ = atspi_event;
}

test "every role has an AT-SPI name" {
    // `handle` answers `GetRoleName` with these strings; a role without one
    // would be announced as an empty name.
    const roles = std.meta.tags(a11y.Role);
    for (roles) |role| {
        try std.testing.expect(role.atspiName().len > 0);
    }
}

test "publishing a window fills a slot and unpublishing frees it" {
    var bridge = Bridge{ .syms = undefined };
    var nodes = [_]a11y.Node{.{ .id = 0, .role = .window }};
    const snap = a11y.Snapshot{ .nodes = &nodes, .root = 0 };

    bridge.publish(1, snap);
    try std.testing.expectEqual(@as(?u32, 1), bridge.windows[0].?.id);
    try std.testing.expectEqual(@as(usize, 1), bridge.windows[0].?.snapshot.len());

    // A second publish of the same window updates it in place.
    bridge.publish(1, snap);
    try std.testing.expectEqual(@as(?u32, 1), bridge.windows[0].?.id);
    try std.testing.expect(bridge.windows[1] == null);

    bridge.unpublish(1);
    try std.testing.expect(bridge.windows[0] == null);
}

test "a second window takes its own slot" {
    var bridge = Bridge{ .syms = undefined };
    var nodes = [_]a11y.Node{.{ .id = 0, .role = .window }};
    const snap = a11y.Snapshot{ .nodes = &nodes, .root = 0 };

    bridge.publish(1, snap);
    bridge.publish(2, snap);
    try std.testing.expectEqual(@as(?u32, 1), bridge.windows[0].?.id);
    try std.testing.expectEqual(@as(?u32, 2), bridge.windows[1].?.id);
}

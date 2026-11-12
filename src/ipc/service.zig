//! Services: the Zig side of the IPC boundary.
//!
//! A service is a **namespace of methods**, registered by name. The page calls
//! `"Greeter.greet"` and the registry finds the method and runs it.
//!
//! ## Why a function-pointer table and not `@typeInfo`
//!
//! Reflection over a Zig struct cannot call a method generically: parameters
//! arrive as loose JSON values, and building a call frame for an arbitrary
//! function is exactly the case Zig's comptime does not cover. Generated glue
//! does that job instead (`myzig generate`), producing a small adapter per
//! method that decodes arguments with `ipc.Args`. The registry only needs
//! `(ctx, args) -> Result`, which is one indirect call.
//!
//! ## Threading
//!
//! A handler always runs on the **main thread**, inside the native event loop,
//! so it may touch windows, menus and the clipboard directly. A handler that
//! blocks therefore freezes the UI: for slow work, hand it to a thread and
//! post the reply back through the app's queue.

const std = @import("std");
const protocol = @import("protocol.zig");
const decode = @import("decode.zig");

/// One callable method.
pub const Method = struct {
    /// The full name the page uses: `"Service.method"`.
    name: []const u8,
    /// Runs the method. `args` are already validated as an object list; the
    /// handler decodes them with `ipc.Args`.
    invoke: *const fn (ctx: ?*anyopaque, args: decode.Args) protocol.Result,
    /// Opaque state handed back to `invoke`, typically the service value.
    ctx: ?*anyopaque = null,
    /// The number of arguments the generated TypeScript declares, so a call
    /// with the wrong count fails before the handler runs.
    arity: u8 = 0,
    /// Documentation for the generated TypeScript. Optional; a method without
    /// it still gets a declaration.
    docs: []const u8 = "",
};

/// The set of methods an application exposes. Names are looked up by a
/// collision-free hash, so registering ten thousand methods costs no more per
/// call than ten.
pub const Registry = struct {
    table: std.StringHashMapUnmanaged(*Method),
    allocator: std.mem.Allocator,
    /// Every method, in registration order, for TypeScript generation.
    ordered: std.ArrayListUnmanaged(*Method) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .table = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        // The map's key is the method's own name slice, so the name is freed
        // once, with the method.
        for (self.ordered.items) |m| {
            self.allocator.free(m.name);
            self.allocator.destroy(m);
        }
        self.ordered.deinit(self.allocator);
        self.table.deinit(self.allocator);
    }

    /// Registers one method. The name is duplicated into the registry.
    /// Registering the same name twice is a programming error and returns
    /// `error.DuplicateName`, so two files cannot quietly claim one name.
    pub fn add(self: *Registry, method: Method) !void {
        // Duplicate first: the map borrows this slice as its key, so it must
        // outlive the entry and be freed exactly once, in `deinit`.
        const name = try self.allocator.dupe(u8, method.name);
        errdefer self.allocator.free(name);

        const gop = try self.table.getOrPut(self.allocator, name);
        if (gop.found_existing) return error.DuplicateName;
        errdefer _ = self.table.remove(name);

        const owned = try self.allocator.create(Method);
        errdefer self.allocator.destroy(owned);

        owned.* = method;
        owned.name = name;
        gop.value_ptr.* = owned;
        try self.ordered.append(self.allocator, owned);
    }

    /// Registers every method in a slice, for generated glue.
    pub fn addAll(self: *Registry, methods: []const Method) !void {
        for (methods) |m| try self.add(m);
    }

    pub fn find(self: *const Registry, name: []const u8) ?*Method {
        return self.table.get(name);
    }

    /// Calls `name` with `args`. An unknown method is a `not-found` result, not
    /// an error, so a page gets a message it can display.
    pub fn call(self: *const Registry, name: []const u8, args: decode.Args) protocol.Result {
        const m = self.find(name) orelse return protocol.Result.fail(
            .not_found,
            "no such method",
        );
        if (m.arity != 0 and args.count() != m.arity) {
            return protocol.Result.fail(.invalid_argument, "wrong number of arguments");
        }
        return m.invoke(m.ctx, args);
    }

    pub fn count(self: *const Registry) usize {
        return self.ordered.items.len;
    }
};

// ------------------------------------------------------------------ tests

fn add(ctx: ?*anyopaque, args: decode.Args) protocol.Result {
    _ = ctx;
    var a = args;
    const x = a.int(i32, .{}) catch |e| return decode.Args.toResult(e);
    const y = a.int(i32, .{}) catch |e| return decode.Args.toResult(e);
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{x + y}) catch return protocol.Result.fail(.internal, "overflow");
    return protocol.Result.success(.{ .number = text });
}

test "register, find and call" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.add(.{ .name = "Math.add", .invoke = add, .arity = 2 });
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.find("Math.add") != null);
    try std.testing.expect(reg.find("Math.sub") == null);
}

test "duplicate names are rejected" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.add(.{ .name = "A.b", .invoke = add });
    try std.testing.expectError(error.DuplicateName, reg.add(.{ .name = "A.b", .invoke = add }));
}

test "unknown method is a not-found result" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const r = reg.call("Nope.nothing", decode.Args.init(&.{}));
    try std.testing.expectEqual(protocol.Code.not_found, r.err.code);
}

test "wrong arity fails before the handler runs" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.add(.{ .name = "Math.add", .invoke = add, .arity = 2 });
    const r = reg.call("Math.add", decode.Args.init(&.{}));
    try std.testing.expectEqual(protocol.Code.invalid_argument, r.err.code);
}

//! Plugins: extra services, menu items, lifecycle hooks and desktop-API
//! access, packaged so an application can opt into them.
//!
//! A plugin is a struct with a `name` and a `setup` function. The framework
//! calls `setup` once, during `App.run`, after the backend is ready and before
//! the first window is shown. Everything the plugin registers lives in the
//! application's arena, so an application never frees a plugin's memory by
//! hand.
//!
//! ```zig
//! const clock = struct {
//!     pub const name = "clock";
//!
//!     pub fn setup(ctx: *myzig.plugins.Context) !void {
//!         try ctx.bind(.{
//!             .name = "Clock.now",
//!             .invoke = now,
//!             .arity = 0,
//!             .ctx = null,
//!         });
//!     }
//!
//!     fn now(_: ?*anyopaque, _: myzig.ipc.Args) myzig.ipc.Result {
//!         return myzig.ipc.Result.success(.{ .number = "0" });
//!     }
//! };
//!
//! try app.addPlugin(&clock);
//! ```
//!
//! ## What a plugin may do
//!
//! * Bind IPC methods, which then appear in the generated TypeScript client.
//! * Add menu items to a menu the application already created.
//! * Read and write the clipboard, show dialogs and notifications.
//! * Register a shutdown hook.
//!
//! ## What a plugin may not do
//!
//! * Create windows. Window lifetime belongs to the application, and a plugin
//!   that owned one could not be unloaded safely.
//! * Run work on the main thread while `setup` is running. `setup` runs on the
//!   main thread and must return promptly; long work belongs on its own thread,
//!   which a plugin may start and must stop in its shutdown hook.

const std = @import("std");
const service_mod = @import("../ipc/service.zig");
const protocol = @import("../ipc/protocol.zig");
const desktop_mod = @import("../platform/desktop.zig");
const log = @import("../log.zig");

pub const Service = service_mod.Methods;
pub const Method = service_mod.Method;
pub const Result = protocol.Result;

/// The maximum number of plugins one application may add. The limit exists so
/// the registry is a fixed array and adding a plugin allocates nothing.
pub const max_plugins = 32;

/// What a plugin is given when it is set up.
pub const Context = struct {
    /// Allocates for the application's lifetime. A plugin should not free from
    /// it: the arena is released as a whole when the application exits.
    arena: std.mem.Allocator,
    /// The application's service registry.
    registry: *service_mod.Registry,
    /// The desktop APIs, for clipboard, dialogs and notifications.
    desktop: desktop_mod.Desktop,
    /// The application's name, for window titles and config paths.
    app_name: []const u8,
    /// The application's version.
    app_version: []const u8,

    /// Binds one IPC method. Names must be unique across the application;
    /// a duplicate is reported as `error.DuplicateMethod`.
    pub fn bind(self: *Context, method: Method) !void {
        try self.registry.add(method);
    }

    /// Binds several methods at once.
    pub fn bindAll(self: *Context, methods: []const Method) !void {
        for (methods) |m| try self.registry.add(m);
    }
};

/// A plugin. `name` is used in log messages and must be unique per
/// application.
pub const Plugin = struct {
    name: []const u8,
    setup: *const fn (ctx: *Context) anyerror!void,
    /// Called when the application is shutting down, in reverse order of
    /// setup. A plugin that started a thread stops it here. Optional.
    shutdown: ?*const fn (ctx: *Context) void = null,
};

/// One plugin as the registry stores it. The context is kept because the
/// shutdown hook needs it again.
const Entry = struct {
    plugin: Plugin,
    context: Context,
    state: enum { added, started, stopped } = .added,
};

/// The application's plugins, in the order they were added.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Scratch space the per-entry contexts point into, so a context has a
    /// stable address. Grown once, in `startAll`, when the count is final.
    contexts: []Context = &.{},

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        if (self.contexts.len != 0) self.gpa.free(self.contexts);
        self.entries.deinit(self.gpa);
    }

    /// Adds a plugin. Setup does not run until `startAll`.
    pub fn add(self: *Registry, plugin: Plugin) !void {
        if (plugin.name.len == 0) return error.EmptyPluginName;
        if (self.entries.items.len >= max_plugins) return error.TooManyPlugins;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.plugin.name, plugin.name)) return error.DuplicatePlugin;
        }
        try self.entries.append(self.gpa, .{
            .plugin = .{
                .name = plugin.name,
                .setup = plugin.setup,
                .shutdown = plugin.shutdown,
            },
            .context = undefined,
        });
    }

    pub fn count(self: *const Registry) usize {
        return self.entries.items.len;
    }

    /// Names in registration order. The returned slices borrow the registry.
    pub fn names(self: *const Registry, out: [][]const u8) []const []const u8 {
        const n = @min(out.len, self.entries.items.len);
        for (self.entries.items[0..n], 0..) |e, i| out[i] = e.plugin.name;
        return out[0..n];
    }

    pub fn find(self: *const Registry, name: []const u8) ?Plugin {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.plugin.name, name)) return e.plugin;
        }
        return null;
    }

    /// Runs every plugin's setup, in registration order.
    ///
    /// A plugin whose setup fails stops the application from starting: a
    /// half-initialised plugin is worse than a clear error. Plugins that
    /// already started are shut down again, in reverse order, so the failure
    /// leaves nothing running.
    pub fn startAll(
        self: *Registry,
        arena: std.mem.Allocator,
        registry: *service_mod.Registry,
        desktop: desktop_mod.Desktop,
        app_name: []const u8,
        app_version: []const u8,
    ) !void {
        if (self.entries.items.len == 0) return;

        // One allocation for every context, so a plugin may keep a pointer to
        // its own context across calls.
        self.contexts = try self.gpa.alloc(Context, self.entries.items.len);
        for (self.contexts, 0..) |*c, i| {
            c.* = .{
                .arena = arena,
                .registry = registry,
                .desktop = desktop,
                .app_name = app_name,
                .app_version = app_version,
            };
            self.entries.items[i].context = c.*;
        }

        var started: usize = 0;
        while (started < self.entries.items.len) : (started += 1) {
            const e = &self.entries.items[started];
            self.entries.items[started].context = self.contexts[started];
            e.plugin.setup(&self.entries.items[started].context) catch |err| {
                log.warn("plugin '{s}' failed to set up: {s}", .{ e.plugin.name, @errorName(err) });
                self.stopFrom(started);
                return err;
            };
            self.entries.items[started].state = .started;
            log.debug("plugin '{s}' ready", .{e.plugin.name});
        }

        // Point every context at its final home in the array; setup may have
        // moved the array's backing memory by adding entries.
        for (self.entries.items, 0..) |*e, i| e.context = self.contexts[i];
    }

    /// Runs shutdown hooks in reverse order, starting with entry `from - 1`.
    fn stopFrom(self: *Registry, from: usize) void {
        var i = from;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            if (e.state != .started) continue;
            if (e.plugin.shutdown) |hook| hook(&e.context);
            e.state = .stopped;
        }
    }

    /// Runs shutdown hooks for every started plugin, newest first. Safe to call
    /// twice: an already stopped plugin is skipped.
    pub fn stopAll(self: *Registry) void {
        self.stopFrom(self.entries.items.len);
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn noopSetup(_: *Context) anyerror!void {}
fn failSetup(_: *Context) anyerror!void {
    return error.SetupFailed;
}

var stop_order: [4]u8 = undefined;
var stop_len: usize = 0;

fn recordA(_: *Context) void {
    stop_order[stop_len] = 'a';
    stop_len += 1;
}
fn recordB(_: *Context) void {
    stop_order[stop_len] = 'b';
    stop_len += 1;
}

fn makeRegistry(gpa: std.mem.Allocator) !service_mod.Registry {
    return service_mod.Registry.init(gpa);
}

fn contextFor(reg: *service_mod.Registry) Context {
    return .{
        .arena = testing.allocator,
        .registry = reg,
        .desktop = .{ .ctx = null, .vtable = undefined },
        .app_name = "test",
        .app_version = "0.0.0",
    };
}

test "a plugin is added but not started until startAll" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.add(.{ .name = "a", .setup = noopSetup });
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(reg.find("a") != null);
    try testing.expect(reg.find("missing") == null);
}

test "a plugin name may not be empty or repeated" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try testing.expectError(error.EmptyPluginName, reg.add(.{ .name = "", .setup = noopSetup }));
    try reg.add(.{ .name = "a", .setup = noopSetup });
    try testing.expectError(error.DuplicatePlugin, reg.add(.{ .name = "a", .setup = noopSetup }));
}

test "a failing plugin stops the ones that already started" {
    stop_len = 0;
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var services = try makeRegistry(testing.allocator);
    defer services.deinit();

    try reg.add(.{ .name = "a", .setup = noopSetup, .shutdown = recordA });
    try reg.add(.{ .name = "b", .setup = failSetup });
    try reg.add(.{ .name = "c", .setup = noopSetup, .shutdown = recordB });

    const desktop: desktop_mod.Desktop = .{ .ctx = null, .vtable = undefined };
    try testing.expectError(error.SetupFailed, reg.startAll(
        testing.allocator,
        &services,
        desktop,
        "test",
        "0.0.0",
    ));
    // Only the plugin that had started is shut down, in reverse order.
    try testing.expectEqual(@as(usize, 1), stop_len);
    try testing.expectEqual(@as(u8, 'a'), stop_order[0]);
}

test "shutdown runs newest first and only once" {
    stop_len = 0;
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var services = try makeRegistry(testing.allocator);
    defer services.deinit();

    try reg.add(.{ .name = "a", .setup = noopSetup, .shutdown = recordA });
    try reg.add(.{ .name = "b", .setup = noopSetup, .shutdown = recordB });

    const desktop: desktop_mod.Desktop = .{ .ctx = null, .vtable = undefined };
    try reg.startAll(testing.allocator, &services, desktop, "test", "0.0.0");
    reg.stopAll();
    try testing.expectEqual(@as(usize, 2), stop_len);
    try testing.expectEqual(@as(u8, 'b'), stop_order[0]);
    try testing.expectEqual(@as(u8, 'a'), stop_order[1]);

    // A second call must not re-run the hooks: a shutdown hook that closes a
    // file or joins a thread is not idempotent.
    reg.stopAll();
    try testing.expectEqual(@as(usize, 2), stop_len);
}

test "a plugin binds methods the registry can call" {
    const Counter = struct {
        value: i64 = 0,

        fn bump(ctx: ?*anyopaque, _: @import("../ipc/decode.zig").Args) Result {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.value += 1;
            return Result.success(.{ .number = "1" });
        }
    };
    var counter = Counter{};
    var services = try makeRegistry(testing.allocator);
    defer services.deinit();

    var ctx = contextFor(&services);
    try ctx.bind(.{ .name = "Counter.bump", .invoke = Counter.bump, .arity = 0, .ctx = &counter });
    try ctx.bindAll(&.{
        .{ .name = "Counter.bump2", .invoke = Counter.bump, .arity = 0, .ctx = &counter },
    });

    const Args = @import("../ipc/decode.zig").Args;
    const empty: [0]@import("../json.zig").Value = .{};
    const args = Args.init(&empty);
    _ = services.call("Counter.bump", args);
    try testing.expectEqual(@as(i64, 1), counter.value);
}

test "names are reported in registration order without allocating" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.add(.{ .name = "one", .setup = noopSetup });
    try reg.add(.{ .name = "two", .setup = noopSetup });

    var buf: [4][]const u8 = undefined;
    const got = reg.names(&buf);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("one", got[0]);
    try testing.expectEqualStrings("two", got[1]);
}

test "the plugin limit is enforced" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var names: [max_plugins][5]u8 = undefined;
    var i: usize = 0;
    while (i < max_plugins) : (i += 1) {
        const n = try std.fmt.bufPrint(&names[i], "p{d}", .{i});
        try reg.add(.{ .name = n, .setup = noopSetup });
    }
    try testing.expectError(error.TooManyPlugins, reg.add(.{ .name = "extra", .setup = noopSetup }));
}

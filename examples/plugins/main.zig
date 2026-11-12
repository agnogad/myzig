//! A plugin that binds its own service and cleans up on shutdown.
//!
//!     zig build plugins
//!
//! The plugin owns a counter and a background thread that ticks it. The page
//! reads the count; quitting the window stops the thread through the plugin's
//! shutdown hook, so the process exits without a dangling thread.

const std = @import("std");
const myzig = @import("myzig");

/// The plugin's own state. It lives in `main` and is handed to the plugin
/// through a module-level pointer, because the framework's setup hook has no
/// closure of its own.
const Ticker = struct {
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    app: ?*myzig.App = null,

    fn loop(self: *Ticker) void {
        while (self.running.load(.acquire)) {
            sleepMs(200);
            const n = self.count.fetchAdd(1, .monotonic) + 1;
            // An event reaches every page subscribed to it. It is safe to emit
            // from another thread: the framework queues it to the main thread.
            if (self.app) |app| {
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch continue;
                _ = app.emit("ticker", .{ .string = text });
            }
        }
    }
};

var ticker: Ticker = .{};

/// Sleeps without pulling in `std.Io`. The plugin thread only needs to wait,
/// and `nanosleep` is the primitive the standard library uses underneath.
fn sleepMs(ms: u64) void {
    const ts = std.posix.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

var reply_buf: [64]u8 = undefined;

fn read(ctx: ?*anyopaque, _: myzig.ipc.Args) myzig.ipc.Result {
    const self: *Ticker = @ptrCast(@alignCast(ctx.?));
    const n = self.count.load(.monotonic);
    const text = std.fmt.bufPrint(&reply_buf, "{d}", .{n}) catch
        return myzig.ipc.Result.fail(.internal, "reply too large");
    return myzig.ipc.Result.success(.{ .number = text });
}

fn setup(ctx: *myzig.plugins.Context) !void {
    // A plugin binds service methods exactly as the application does.
    try ctx.bind(.{
        .name = "Ticker.count",
        .invoke = read,
        .arity = 0,
        .ctx = &ticker,
    });

    ticker.running.store(true, .release);
    ticker.thread = try std.Thread.spawn(.{}, Ticker.loop, .{&ticker});
}

fn shutdown(_: *myzig.plugins.Context) void {
    ticker.running.store(false, .release);
    if (ticker.thread) |t| t.join();
    ticker.thread = null;
}

const plugin: myzig.plugins.Plugin = .{
    .name = "ticker",
    .setup = setup,
    .shutdown = shutdown,
};

const frontend = [_]myzig.FrontendFile{
    .{
        .path = "index.html",
        .mime = "text/html; charset=utf-8",
        .data = @embedFile("assets/index.html"),
    },
    .{
        .path = "app.js",
        .mime = "text/javascript",
        .data = @embedFile("assets/app.js"),
    },
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Plugins",
        .app_id = "dev.myzig.plugins",
        .frontend = &frontend,
    });
    defer app.deinit();

    // The plugin needs the app to emit events from its thread.
    ticker.app = &app;
    try app.addPlugin(plugin);

    _ = try app.createWindow(.{
        .title = "Plugins",
        .width = 640,
        .height = 320,
        .url = "myzig://app/index.html",
    });

    try app.run();
}

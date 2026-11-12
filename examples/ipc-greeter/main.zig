//! Typed Zig <-> TypeScript calls, end to end.
//!
//!     zig build ipc-greeter
//!
//! The page calls `myzig.call("Greeter.greet", name)`; Zig runs
//! `greet`, which also emits an event the page listens for.

const std = @import("std");
const myzig = @import("myzig");

/// Application state handed to every handler. Storing the app here is how a
/// handler reaches the framework: it runs on the main thread inside the loop,
/// so it may touch windows directly.
const State = struct {
    app: *myzig.App,
    greeted: usize = 0,
};

/// Output buffers shared by the handlers. A returned `json.Value` must outlive
/// the handler, so it cannot point at a local variable.
var reply_buf: [192]u8 = undefined;
var reply_text: []const u8 = "";

fn greet(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state: *State = @ptrCast(@alignCast(ctx.?));

    // Arguments are decoded with explicit rules; a wrong type or a missing
    // argument becomes a protocol error the page can display.
    var a = args;
    const name = a.stringBounded(64) catch |e| return myzig.ipc.Args.toResult(e);

    state.greeted += 1;

    // Emit before replying is fine: both reach the page in the same turn, and
    // the page's listener is already registered.
    _ = state.app.emit("greeted", .{ .string = name });

    // The reply value must outlive this handler.
    reply_text = std.fmt.bufPrint(&reply_buf, "Hello, {s}! You are greeting #{d}.", .{ name, state.greeted }) catch
        return myzig.ipc.Result.fail(.internal, "reply too large");
    return myzig.ipc.Result.success(.{ .string = reply_text });
}

fn increment(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state: *State = @ptrCast(@alignCast(ctx.?));
    state.greeted += 1;
    return myzig.ipc.Result.success(.null);
}

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
        .name = "Greeter",
        .app_id = "dev.myzig.greeter",
        .frontend = &frontend,
    });
    defer app.deinit();

    // State lives in `main`, so it outlives the loop.
    var state = State{ .app = &app };

    // Registration is explicit: the name here is exactly what the page calls.
    try app.bind(.{
        .name = "Greeter.greet",
        .invoke = greet,
        .ctx = &state,
        .arity = 1,
    });
    try app.bind(.{
        .name = "Greeter.increment",
        .invoke = increment,
        .ctx = &state,
        .arity = 0,
    });

    _ = try app.createWindow(.{
        .title = "Greeter",
        .width = 720,
        .height = 460,
        .url = "myzig://app/index.html",
    });

    try app.run();
}

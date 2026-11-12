//! Project templates for `myzig new`.
//!
//! The templates are plain multi-line strings, kept apart from the argument
//! parsing so a placeholder is visible as `@@name@@` rather than as a brace
//! that Zig's format machinery would try to interpret. `substitute` fills them.

const std = @import("std");

/// Replaces `@@key@@` with `value` in every template.
pub fn substitute(allocator: std.mem.Allocator, template: []const u8, values: []const Substitution) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '@' and template[i + 1] == '@') {
            const close = std.mem.indexOfPos(u8, template, i + 2, "@@") orelse {
                try out.append(allocator, template[i]);
                i += 1;
                continue;
            };
            const key = template[i + 2 .. close];
            var replaced = false;
            for (values) |v| {
                if (std.mem.eql(u8, v.key, key)) {
                    try out.appendSlice(allocator, v.value);
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                // An unknown key would silently produce a broken project, so it
                // is left visible and the caller's test catches it.
                try out.append(allocator, '@');
                i += 1;
                continue;
            }
            i = close + 2;
            continue;
        }
        try out.append(allocator, template[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

pub const Substitution = struct {
    key: []const u8,
    value: []const u8,
};

/// Zig validates the fingerprint's low half against the CRC32 of the package
/// name, so `myzig new` computes it rather than leaving the field out.
pub const build_zon =
    \\.{
    \\    .name = .@@name@@,
    \\    .version = "0.1.0",
    \\    .fingerprint = @@fingerprint@@,
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = .{
    \\        .myzig = .{ .path = "@@framework@@" },
    \\    },
    \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
    \\}
    \\
;

pub const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // The framework is the dependency declared in build.zig.zon.
    \\    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize });
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "@@name@@",
    \\        .root_module = b.createModule(.{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\            .link_libc = true,
    \\        }),
    \\    });
    \\    exe.root_module.addImport("myzig", myzig.module("myzig"));
    \\    b.installArtifact(exe);
    \\
    \\    const run = b.addRunArtifact(exe);
    \\    b.step("run", "Run the application").dependOn(&run.step);
    \\}
    \\
;

pub const main_web =
    \\//! A MyZig application: one window showing a page, wired to Zig.
    \\
    \\const std = @import("std");
    \\const myzig = @import("myzig");
    \\
    \\var reply_buf: [256]u8 = undefined;
    \\
    \\fn greet(_: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    \\    var a = args;
    \\    const who = a.stringBounded(64) catch |e| return myzig.ipc.Args.toResult(e);
    \\    const text = std.fmt.bufPrint(&reply_buf, "Hello, {s}!", .{who}) catch
    \\        return myzig.ipc.Result.fail(.internal, "reply too large");
    \\    return myzig.ipc.Result.success(.{ .string = text });
    \\}
    \\
    \\pub fn main() !void {
    \\    var gpa_state = std.heap.DebugAllocator(.{}){};
    \\    defer _ = gpa_state.deinit();
    \\
    \\    var app = try myzig.App.init(gpa_state.allocator(), .{
    \\        .name = "@@name@@",
    \\        .app_id = "dev.myzig.@@slug@@",
    \\        .frontend = &.{
    \\            .{ .path = "index.html", .data = @embedFile("index.html"), .mime = "text/html" },
    \\            .{ .path = "app.js", .data = @embedFile("app.js"), .mime = "text/javascript" },
    \\        },
    \\    });
    \\    defer app.deinit();
    \\
    \\    // The page calls `Hello.greet` and gets an answer back. The reply value
    \\    // has to outlive the handler, so it is formatted into a file-scope buffer.
    \\    try app.bind(.{
    \\        .name = "Hello.greet",
    \\        .invoke = greet,
    \\        .arity = 1,
    \\    });
    \\
    \\    _ = try app.createWindow(.{ .title = "@@name@@", .width = 800, .height = 600 });
    \\    try app.run();
    \\}
    \\
;

pub const main_native =
    \\//! A MyZig application drawn by MyZig itself: no page, no web engine.
    \\
    \\const std = @import("std");
    \\const myzig = @import("myzig");
    \\const ui = myzig.ui;
    \\
    \\/// What the window shows. It lives in `main`, so it outlives the window, and
    \\/// it is handed to the draw callback as its context.
    \\const State = struct {
    \\    title: []const u8,
    \\    clicks: u32 = 0,
    \\};
    \\
    \\fn draw(ctx: *anyopaque, builder: *anyopaque, size: myzig.platform.DrawRect, scale: f32) void {
    \\    _ = scale;
    \\    const b: *ui.Builder = @ptrCast(@alignCast(builder));
    \\    const state: *State = @ptrCast(@alignCast(ctx));
    \\
    \\    b.fillRect(.{ .x = 0, .y = 0, .width = size.width, .height = size.height }, ui.Color.rgb(0xf7f8fa)) catch return;
    \\    b.fillRect(.{ .x = 0, .y = 0, .width = size.width, .height = 48 }, ui.Color.rgb(0x2f6fed)) catch return;
    \\    b.text(.{ .x = 16, .y = 16, .width = 400, .height = 16 }, state.title, ui.Color.white, 2) catch return;
    \\
    \\    // Text is copied by the builder, so a stack buffer is correct here: the
    \\    // frame is rasterised after this callback returns.
    \\    var buf: [64]u8 = undefined;
    \\    const line = std.fmt.bufPrint(&buf, "Clicks: {d}", .{state.clicks}) catch return;
    \\    b.text(.{ .x = 16, .y = 80, .width = 400, .height = 24 }, line, ui.Color.rgb(0x1a1d21), 3) catch return;
    \\
    \\    b.fillRect(.{ .x = 16, .y = 130, .width = 160, .height = 44 }, ui.Color.rgb(0x2f6fed)) catch return;
    \\    b.text(.{ .x = 40, .y = 143, .width = 160, .height = 16 }, "+1 click", ui.Color.white, 2) catch return;
    \\}
    \\
    \\/// Handles a pointer press. Returning true asks for a new frame, which is what
    \\/// makes the counter appear.
    \\fn onPress(state: *State, x: f32, y: f32) bool {
    \\    if (x < 16 or x > 176 or y < 130 or y > 174) return false;
    \\    state.clicks += 1;
    \\    return true;
    \\}
    \\
    \\pub fn main() !void {
    \\    var gpa_state = std.heap.DebugAllocator(.{}){};
    \\    defer _ = gpa_state.deinit();
    \\
    \\    var app = try myzig.App.init(gpa_state.allocator(), .{
    \\        .name = "@@name@@",
    \\        .app_id = "dev.myzig.@@slug@@",
    \\    });
    \\    defer app.deinit();
    \\
    \\    var state = State{ .title = "@@name@@" };
    \\    app.setSurfaceInput(State, &state, onPress);
    \\
    \\    _ = try app.createWindow(.{
    \\        .title = "@@name@@",
    \\        .width = 800,
    \\        .height = 600,
    \\        .native_draw = .{ .func = draw, .ctx = &state },
    \\    });
    \\    try app.run();
    \\}
    \\
;

pub const index_html =
    \\<!doctype html>
    \\<html>
    \\  <head>
    \\    <meta charset="utf-8" />
    \\    <title>@@name@@</title>
    \\    <style>
    \\      body { font: 16px system-ui, sans-serif; margin: 2rem; }
    \\    </style>
    \\  </head>
    \\  <body>
    \\    <h1 id="msg">Connecting...</h1>
    \\    <script src="app.js"></script>
    \\  </body>
    \\</html>
    \\
;

pub const app_js =
    \\// Once the bridge is ready, call Zig and show the answer. Arguments are
    \\// passed one by one, matching the method's arity.
    \\window.myzig.on("myzig:ready", async () => {
    \\  const greeting = await window.myzig.call("Hello.greet", "MyZig");
    \\  document.getElementById("msg").textContent = String(greeting);
    \\});
    \\
;

test "substitution replaces every placeholder" {
    const out = try substitute(std.testing.allocator, "a @@x@@ b @@y@@", &.{
        .{ .key = "x", .value = "1" },
        .{ .key = "y", .value = "2" },
    });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a 1 b 2", out);
}

test "a template with no placeholder is returned unchanged" {
    const out = try substitute(std.testing.allocator, "plain text", &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain text", out);
}

test "the templates carry the placeholders they need" {
    try std.testing.expect(std.mem.indexOf(u8, main_web, "@@name@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_web, "@@slug@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, main_native, "@@name@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "@@name@@") != null);
}

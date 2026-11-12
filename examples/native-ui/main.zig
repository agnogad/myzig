//! A native UI window: no page, no WebKit, no scripting engine.
//!
//! Everything on screen is drawn by MyZig itself, from a layout tree and a
//! drawing list, into a pixel buffer that the platform blits. Clicking a button
//! changes plain Zig state and the next frame shows it.
//!
//! `MYZIG_NATIVE_EXAMPLE=click` presses the "+1" button a few times through the
//! same path a pointer takes, so a headless script can prove the input wiring.

const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const State = struct {
    clicks: i32 = 0,
    dark: bool = false,
    /// Set by a screen reader through the accessibility tree, and by nothing
    /// else: it exists to prove a reader can change a value, not just read one.
    opacity: u8 = 60,
};

/// Frames from the last paint, so a click and a frame agree about where each
/// button is. Written by `draw`, read by `press`.
var frames: [3]ui.Rect = .{ .zero, .zero, .zero };

/// Buttons, in draw order. The labels are constant; only the frames change.
const labels = [_][]const u8{ "+1", "+10", "Theme" };

/// Describes the window to a screen reader: the same labels and frames that
/// `draw` puts on screen, in the order a reader walks them.
fn setOpacity(ctx: *anyopaque, value: f64) void {
    const opacity: *u8 = @ptrCast(@alignCast(ctx));
    opacity.* = @intFromFloat(@max(0, @min(255, value)));
}

fn describe(ctx: *anyopaque, builder: *anyopaque, size: myzig.platform.backend.DrawRect) void {
    _ = size;
    const state: *State = @ptrCast(@alignCast(ctx));
    const b: *ui.a11y.Builder = @ptrCast(@alignCast(builder));

    b.setName(0, "MyZig native UI") catch return;
    b.setDescription(0, "A window drawn by MyZig, with no web engine.") catch return;

    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Clicks: {d}", .{state.clicks}) catch "Clicks";
    _ = b.leaf(.label, .{ .x = 16, .y = 72, .width = 240, .height = 16 }, line) catch return;

    // A node with a value publishes the Text and Value interfaces, which is
    // what a reader needs to announce what is in it rather than that it exists.
    const slider = b.beginNode(.slider, .{ .x = 16, .y = 220, .width = 240, .height = 20 }) catch return;
    b.setName(slider, "Opacity") catch return;
    var pct_buf: [8]u8 = undefined;
    const pct = std.fmt.bufPrint(&pct_buf, "{d}%", .{state.opacity}) catch "?";

    b.setValue(slider, pct) catch return;
    b.setNumber(slider, .{
        .value = @floatFromInt(state.opacity),
        .min = 0,
        .max = 100,
        .step = 5,
        // A reader that asks for a value gets it: the callback runs on the
        // toolkit thread, so the state it changes is the state `draw` reads.
        .setter = .{ .call = setOpacity, .ctx = &state.opacity },
    });
    b.endNode();

    for (labels, 0..) |label, i| {
        const id = b.beginNode(.button, frames[i]) catch return;
        b.setName(id, label) catch return;
        // A reader can press these, not just read them.
        b.setPressAction(id, label) catch return;
        b.endNode();
    }
}

fn draw(ctx: *anyopaque, builder: *anyopaque, size: myzig.platform.backend.DrawRect, scale: f32) void {
    _ = scale;
    const state: *State = @ptrCast(@alignCast(ctx));
    const b: *ui.canvas.Builder = @ptrCast(@alignCast(builder));

    const dark = state.dark;
    b.fillRect(
        .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
        if (dark) ui.Color.rgb(0x14161a) else ui.Color.rgb(0xf7f8fa),
    ) catch return;

    b.fillRect(
        .{ .x = 0, .y = 0, .width = size.width, .height = 48 },
        ui.Color.rgb(0x2f6fed),
    ) catch return;
    b.text(.{ .x = 16, .y = 20, .width = 200, .height = 8 }, "MyZig native UI", ui.Color.white, 1) catch return;

    const ink = if (dark) ui.Color.rgb(0xe8eaef) else ui.Color.rgb(0x1b1d22);
    const muted = if (dark) ui.Color.rgb(0x9aa2b1) else ui.Color.rgb(0x5b6270);

    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Clicks: {d}", .{state.clicks}) catch "Clicks: ?";
    b.text(.{ .x = 16, .y = 72, .width = 240, .height = 16 }, line, ink, 1) catch return;
    b.text(.{ .x = 16, .y = 104, .width = 320, .height = 8 }, "No page. No WebKit. Just Zig.", muted, 1) catch return;

    // The value a screen reader can change. Drawn so the change is visible.
    var op_buf: [24]u8 = undefined;
    const op = std.fmt.bufPrint(&op_buf, "Opacity: {d}%", .{state.opacity}) catch "Opacity";
    b.text(.{ .x = 16, .y = 220, .width = 240, .height = 8 }, op, ink, 1) catch return;
    // The font covers Latin-1 and the letters Turkish adds, so an interface
    // can be written in its own language.
    b.text(.{ .x = 16, .y = 128, .width = 400, .height = 8 }, "Türkçe: ışık, çğüşö, İstanbul", muted, 1) catch return;

    // Lay the buttons out with the same engine the rest of the toolkit uses, so
    // their frames come from the layout rather than from hand-added offsets.
    var nodes = [_]ui.layout.Node{ .{ .direction = .horizontal, .spacing = 12 }, .{}, .{}, .{} };
    const kids = [_][]const usize{ &.{ 1, 2, 3 }, &.{}, &.{}, &.{} };
    for (labels, 0..) |label, i| {
        nodes[i + 1].intrinsic = .{
            .width = ui.canvas.textWidth(label, 1) + 32,
            .height = 36,
        };
    }

    var flat = ui.layout.FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = ui.layout.Tree{
        .nodes = &nodes,
        .root = 0,
        .child_of = ui.layout.FlatTree.childrenOf,
        .ctx = &flat,
    };
    ui.layout.layout(tree, .{ .x = 16, .y = 140, .width = size.width - 32, .height = 36 });

    for (labels, 0..) |label, i| {
        frames[i] = nodes[i + 1].frame;
        const frame = nodes[i + 1].frame;
        const selected = i == 2 and dark;
        b.fillRounded(
            frame,
            if (selected) ui.Color.rgb(0x2f6fed) else if (dark) ui.Color.rgb(0x232830) else ui.Color.rgb(0xe4e7ec),
            8,
        ) catch return;
        const tw = ui.canvas.textWidth(label, 1);
        b.text(
            .{
                .x = frame.x + @divTrunc(frame.width - tw, 2),
                .y = frame.y + @divTrunc(frame.height - ui.canvas.textHeight(1), 2),
                .width = tw,
                .height = ui.canvas.textHeight(1),
            },
            label,
            if (selected) ui.Color.white else ink,
            1,
        ) catch return;
    }
}

fn hitTest(x: f32, y: f32) ?usize {
    for (frames, 0..) |frame, i| {
        if (frame.contains(@intFromFloat(x), @intFromFloat(y))) return i;
    }
    return null;
}

/// Applies a press at a point. Returns true when it hit a button.
fn press(state: *State, x: f32, y: f32) bool {
    const index = hitTest(x, y) orelse return false;
    switch (index) {
        0 => state.clicks += 1,
        1 => state.clicks += 10,
        2 => state.dark = !state.dark,
        else => {},
    }
    std.debug.print("native-ui: button {d} pressed, clicks = {d}, dark = {}\n", .{ index, state.clicks, state.dark });
    return true;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Native UI",
        .app_id = "dev.myzig.native-ui",
        .version = "0.1.0",
    });
    defer app.deinit();

    const state = try gpa.create(State);
    state.* = .{};

    app.setSurfaceInput(State, state, press);

    _ = try app.createWindow(.{
        .title = "Native UI",
        .width = 720,
        .height = 260,
        .view = struct {
            fn v(ctx: *anyopaque) void {
                _ = ctx;
            }
        }.v,
        .native_draw = .{ .func = draw, .ctx = state },
        // The same interface, described for a screen reader. Without this the
        // window is a rectangle of pixels to an accessibility client.
        .a11y = .{ .func = describe, .ctx = state },
    });

    std.debug.print("native-ui: window open, no web engine loaded\n", .{});
    try app.run();
}

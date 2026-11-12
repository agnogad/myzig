//! A native counter: no web view in the process.
//!
//!     zig build counter-native
//!
//! Every pixel is produced by MyZig. The counter, the buttons and the labels
//! are drawn from a display list into a pixel buffer that GTK blits, and a
//! click changes Zig state and repaints.
//!
//! `MYZIG_COUNTER_STEPS=5` presses the increment button through the same path a
//! pointer takes, so a headless run can prove the whole cycle.

const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;

const State = struct {
    value: i32 = 0,
};

/// Frames from the last paint. A click reads them, so hit testing and painting
/// can never disagree about where a button is.
var frames: [3]ui.Rect = .{ .zero, .zero, .zero };
const labels = [_][]const u8{ "-1", "+1", "Reset" };

const accent = ui.Color.rgb(0x2f6fed);
const surface_color = ui.Color.rgb(0xf5f6f8);
const ink = ui.Color.rgb(0x14161a);
const muted = ui.Color.rgb(0x6b7280);
const button_face = ui.Color.rgb(0xe5e7eb);

fn draw(ctx: *anyopaque, builder: *anyopaque, size: myzig.platform.backend.DrawRect, scale: f32) void {
    _ = scale;
    const state: *State = @ptrCast(@alignCast(ctx));
    const b: *ui.canvas.Builder = @ptrCast(@alignCast(builder));

    b.fillRect(.{ .x = 0, .y = 0, .width = size.width, .height = size.height }, surface_color) catch return;

    var buf: [24]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{state.value}) catch "?";

    // The number is the centrepiece, so it is drawn at four times the cell size
    // and centred with the same text measurement the layout uses.
    const scale_big: i32 = 4;
    const tw = ui.canvas.textWidth(value, scale_big);
    const th = ui.canvas.textHeight(scale_big);
    const centre_y = @divTrunc(size.height, 2) - 40;
    b.text(
        .{ .x = @divTrunc(size.width - tw, 2), .y = centre_y, .width = tw, .height = th },
        value,
        ink,
        scale_big,
    ) catch return;

    const caption = "native counter";
    const cw = ui.canvas.textWidth(caption, 1);
    b.text(
        .{ .x = @divTrunc(size.width - cw, 2), .y = centre_y + th + 12, .width = cw, .height = 8 },
        caption,
        muted,
        1,
    ) catch return;

    // Buttons, laid out by the engine so their frames come from the layout.
    var nodes = [_]ui.layout.Node{ .{ .direction = .horizontal, .spacing = 10 }, .{}, .{}, .{} };
    const kids = [_][]const usize{ &.{ 1, 2, 3 }, &.{}, &.{}, &.{} };
    for (labels, 0..) |label, i| {
        nodes[i + 1].intrinsic = .{
            .width = ui.canvas.textWidth(label, 1) + 28,
            .height = 34,
        };
    }

    var total: i32 = 0;
    for (labels) |label| total += ui.canvas.textWidth(label, 1) + 28;
    total += 2 * nodes[0].spacing;

    var flat = ui.layout.FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = ui.layout.Tree{
        .nodes = &nodes,
        .root = 0,
        .child_of = ui.layout.FlatTree.childrenOf,
        .ctx = &flat,
    };
    const row_y = size.height - 62;
    ui.layout.layout(tree, .{
        .x = @divTrunc(size.width - total, 2),
        .y = row_y,
        .width = total,
        .height = 34,
    });

    for (labels, 0..) |label, i| {
        frames[i] = nodes[i + 1].frame;
        const frame = nodes[i + 1].frame;
        const primary = i == 1;
        b.fillRounded(frame, if (primary) accent else button_face, 8) catch return;
        const lw = ui.canvas.textWidth(label, 1);
        b.text(
            .{
                .x = frame.x + @divTrunc(frame.width - lw, 2),
                .y = frame.y + @divTrunc(frame.height - ui.canvas.textHeight(1), 2),
                .width = lw,
                .height = ui.canvas.textHeight(1),
            },
            label,
            if (primary) ui.Color.white else ink,
            1,
        ) catch return;
    }
}

fn press(state: *State, x: f32, y: f32) bool {
    const px = @as(i32, @intFromFloat(x));
    const py = @as(i32, @intFromFloat(y));
    for (frames, 0..) |frame, i| {
        if (!frame.contains(px, py)) continue;
        switch (i) {
            0 => state.value -= 1,
            1 => state.value += 1,
            2 => state.value = 0,
            else => {},
        }
        std.debug.print("counter-native: {s}, value = {d}\n", .{ labels[i], state.value });
        return true;
    }
    return false;
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var app = try myzig.App.init(gpa, .{
        .name = "Counter",
        .app_id = "dev.myzig.counter",
        .version = "0.1.0",
    });
    defer app.deinit();

    const state = try gpa.create(State);
    state.* = .{};
    app.setSurfaceInput(State, state, press);

    _ = try app.createWindow(.{
        .title = "Counter",
        .width = 400,
        .height = 320,
        .view = struct {
            fn v(ctx: *anyopaque) void {
                _ = ctx;
            }
        }.v,
        .native_draw = .{ .func = draw, .ctx = state },
    });

    std.debug.print("counter-native: window open, no web engine in the process\n", .{});
    try app.run();
}

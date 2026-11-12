# Native UI

A window can be drawn entirely by MyZig, with no page and no web engine. The
layout engine, the rasteriser and the input routing are all in Zig.

## A window that draws

```zig
_ = try app.createWindow(.{
    .title = "Native",
    .width = 720,
    .height = 260,
    .native_draw = .{ .ctx = &state, .func = draw },
});
```

`draw` is called whenever the surface needs a frame:

```zig
fn draw(ctx: ?*anyopaque, builder: *anyopaque, size: myzig.platform.DrawRect, scale: f32) void {
    _ = scale;
    const b: *myzig.ui.Builder = @ptrCast(@alignCast(builder));
    const state: *State = @ptrCast(@alignCast(ctx.?));

    b.fillRect(.{ .x = 0, .y = 0, .width = size.width, .height = size.height },
        myzig.ui.Color.rgb(0xf7f8fa));
    b.fillRect(.{ .x = 0, .y = 0, .width = size.width, .height = 48 },
        myzig.ui.Color.rgb(0x2f6fed));

    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Clicks: {d}", .{state.clicks}) catch return;
    b.text(.{ .x = 24, .y = 80, .width = 300, .height = 24 }, text,
        myzig.ui.Color.rgb(0x1a1d21), 3);
}
```

**Text is copied by the builder**, so a stack buffer is correct here: the frame
is rasterised after `draw` returns.

## Drawing commands

| Call | Effect |
| --- | --- |
| `fillRect(rect, color)` | fills the rectangle |
| `text(rect, s, color, scale)` | draws `s` at `scale`× the 8×8 bitmap font, clipped to `rect` |

Colours are `Color.rgb(0xRRGGBB)` or `Color.rgba(r, g, b, a)`; blending is
source-over with integer coordinates.

## Layout

A flex-style engine turns a flat tree of nodes into rectangles.

```zig
var nodes = [_]myzig.ui.layout.Node{
    // 0: column, fills the window
    .{ .direction = .vertical, .padding = .all(24), .spacing = 12, .grow = 1 },
    // 1: header, fixed height, stretches across
    .{ .height = 48, .cross_align = .stretch },
    // 2: body, takes the rest
    .{ .grow = 1 },
};

var tree = myzig.ui.layout.Tree{
    .nodes = &nodes,
    .child_of = childrenOf,
    .ctx = &children,
};

myzig.ui.layout.layout(tree, .{ .x = 0, .y = 0, .width = width, .height = height });

// nodes[1].frame is now the header's rectangle.
```

| Field | Meaning |
| --- | --- |
| `direction` | `.horizontal` or `.vertical` |
| `padding`, `margin` | insets inside and around the node |
| `spacing` | gap between children |
| `cross_align` | how children sit across the main axis |
| `justify` | how the children group sits along the main axis |
| `width`, `height` | fixed size; `-1` measures from content |
| `min_*`, `max_*` | clamps |
| `grow` | share of leftover space; `0` keeps the measured size |
| `intrinsic` | content size the view contributes |
| `frame` | written by `layout` |

**Coordinates are integers.** `f32` sizes drift down a tree, and a row of boxes
that should line up ends up a pixel off. Leftover space is divided by grow factor
and the rounding remainder goes to the earliest growers, so the children's frames
add up to the parent exactly.

`cross_align` is named that rather than `align` because `align` is a Zig keyword.

## Input

```zig
app.setSurfaceInput(State, &state, onPress);
```

`setSurfaceInput` takes a comptime state type, a pointer to it and a handler; the
handler returns `true` when it handled the press.

```zig
fn onPress(state: *State, x: f32, y: f32) bool {
    if (x >= 24 and x <= 120 and y >= 120 and y <= 156) {
        state.clicks += 1;
        return true;   // handled: ask for a new frame
    }
    return false;
}
```

Returning `true` requests a repaint. The coordinates are in device-independent
pixels relative to the surface.

## Text

Text uses `src/ui/font8x8.zig`, a bitmap font covering ASCII 32–126. A bitmap
font needs no font-file parser and no shaping, so text appears with no
dependency at all — and the binary costs 95 glyphs.

Text beyond ASCII is **not supported yet**. `text()` skips bytes it has no glyph
for, so a non-ASCII string renders with gaps rather than crashing.

## What is not there yet

* Accessibility (AT-SPI): the tree is not exposed to screen readers.
* GPU rendering: frames are rasterised on the CPU and blitted through cairo.
* Text beyond ASCII.

All three are recorded in [PROGRESS.md](PROGRESS.md).

## Examples

* `examples/native-ui` — a header, a counter and three buttons.
* `examples/counter-native` — the smallest working native application.
* `examples/hybrid` — a native window beside a web window.

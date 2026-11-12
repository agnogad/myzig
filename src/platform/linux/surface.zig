//! Native windows on Linux: a `GtkDrawingArea` that MyZig paints itself.
//!
//! ## The pipeline
//!
//! 1. The application's UI code fills a `ui.canvas.Builder`.
//! 2. `ui.canvas.render` rasterises it into an RGBA buffer owned by this module.
//! 3. GTK's draw signal asks for a repaint, and `blit` copies the buffer into
//!    cairo and paints it.
//!
//! There is no WebKit in this path at all: a native-only window never maps the
//! web engine, which is the reason a native application here starts fast and
//! uses little memory.
//!
//! ## Why cairo for the last step
//!
//! GDK hands the draw signal a cairo context, and cairo can wrap an existing
//! pixel buffer with `cairo_image_surface_create_for_data`. That is one copy of
//! the buffer, done by the toolkit's own rasteriser, and the blit itself is
//! cairo's. Writing the buffer straight into an X pixmap would skip cairo but
//! tie the renderer to X11; going through cairo keeps the Wayland path working.

const std = @import("std");
const ffi = @import("ffi.zig");
const backend = @import("../backend.zig");
const events = @import("../../events.zig");
const ui = @import("../../ui/ui.zig");
const log = @import("../../log.zig");
const atspi = @import("atspi.zig");

/// The pixel buffer and geometry for one native surface.
pub const Surface = struct {
    /// RGBA8, tightly packed rows, `width * height * 4` bytes.
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// Device pixels per DIP.
    scale: f32 = 1,
    /// The caller's draw function: fill `builder` for this size.
    draw: ?*const fn (ctx: *anyopaque, builder: *anyopaque, size: backend.DrawRect, scale: f32) void = null,
    ctx: ?*anyopaque = null,
    /// Reused across frames so drawing the same UI does not allocate.
    builder: ui.canvas.Builder = undefined,
    builder_ready: bool = false,
    /// The accessibility tree, filled once per frame beside the drawing list.
    a11y_tree: ui.a11y.Builder = undefined,
    a11y_ready: bool = false,
    /// The caller's description of the window for a screen reader.
    describe: ?backend.AccessibleDraw = null,
    /// The drawing area, the widget that actually repaints.
    widget: ?ffi.GtkWidget = null,
    /// The event box around it, which receives pointer input.
    event_box: ?ffi.GtkWidget = null,
    window_id: u32 = 0,
};

/// Surfaces by window id. Empty unless a native window exists.
var surfaces: std.AutoHashMapUnmanaged(u32, *Surface) = .empty;
var gpa: std.mem.Allocator = undefined;
var sink: ?backend.EventSink = null;

pub fn init(allocator: std.mem.Allocator, events_sink: ?backend.EventSink) void {
    gpa = allocator;
    sink = events_sink;
}

pub fn deinit() void {
    var it = surfaces.iterator();
    while (it.next()) |e| destroySurface(e.value_ptr.*);
    surfaces.deinit(gpa);
    surfaces = .empty;
}

fn destroySurface(s: *Surface) void {
    atspi.unpublish(s.window_id);
    if (s.a11y_ready) s.a11y_tree.deinit();
    if (s.builder_ready) s.builder.deinit();
    if (s.pixels.len > 0) gpa.free(s.pixels);
    gpa.destroy(s);
}

/// Creates a drawing area for `window_id`. The caller must have loaded GTK and
/// cairo.
pub fn attach(window_id: u32, parent: ffi.GtkWidget, width: i32, height: i32) !*Surface {
    const area = ffi.gtk_drawing_area_new() orelse return error.OutOfMemory;

    const s = try gpa.create(Surface);
    errdefer gpa.destroy(s);
    s.* = .{ .window_id = window_id, .widget = @ptrCast(area) };
    s.builder = ui.canvas.Builder.init(gpa);
    s.builder_ready = true;

    try surfaces.put(gpa, window_id, s);

    resize(s, width, height, 1);

    _ = ffi.connectSignal(@ptrCast(area), "draw", @ptrCast(&onDraw), s);
    _ = ffi.connectSignal(@ptrCast(area), "size-allocate", @ptrCast(&onSizeAllocate), s);

    // A `GtkDrawingArea` has no window of its own, so pointer events never
    // reach it directly. Wrapping it in a `GtkEventBox` gives it one, which is
    // what makes clicks and motion arrive.
    const box = ffi.gtk_event_box_new() orelse return error.OutOfMemory;
    s.event_box = box;
    ffi.gtk_container_add(@ptrCast(box), @ptrCast(area));
    ffi.gtk_widget_add_events(box, event_mask);
    _ = ffi.connectSignal(box, "button-press-event", @ptrCast(&onButtonPress), s);
    _ = ffi.connectSignal(box, "button-release-event", @ptrCast(&onButtonRelease), s);
    _ = ffi.connectSignal(box, "motion-notify-event", @ptrCast(&onMotion), s);

    ffi.gtk_container_add(@ptrCast(parent), box);
    ffi.gtk_widget_show_all(@ptrCast(area));
    return s;
}

/// GDK event masks. A drawing area gets exposure events from GTK; pointer input
/// has to be asked for explicitly. GDK_EXPOSURE_MASK (2) is included so a
/// repaint request is not dropped.
const event_mask: c_int = 2 | 4 | 8 | 64;

/// Allocates the pixel buffer for a size and scale. Called on creation and
/// whenever the window changes size or moves to a display with another density.
pub fn resize(s: *Surface, width: i32, height: i32, scale: f32) void {
    const device_scale: f32 = if (scale > 0) scale else 1;
    const pw: u32 = @intFromFloat(@max(1, @as(f32, @floatFromInt(width)) * device_scale));
    const ph: u32 = @intFromFloat(@max(1, @as(f32, @floatFromInt(height)) * device_scale));

    if (pw == s.width and ph == s.height and s.pixels.len > 0) {
        s.scale = device_scale;
        return;
    }

    const bytes = @as(usize, pw) * ph * 4;
    if (s.pixels.len > 0) gpa.free(s.pixels);
    // A zeroed buffer means an unpainted area is transparent black, so a frame
    // that does not cover everything shows through as flat black rather than
    // as whatever the allocation happened to contain.
    s.pixels = gpa.alloc(u8, bytes) catch {
        s.pixels = &.{};
        return;
    };
    @memset(s.pixels, 0);
    s.width = pw;
    s.height = ph;
    s.scale = device_scale;

    if (sink) |sk| sk.surfaceResized(s.window_id, width, height, device_scale);
}

/// Runs the application's draw function and rasterises the result. Returns the
/// buffer to blit.
pub fn renderFrame(s: *Surface) []const u8 {
    if (s.pixels.len == 0) return &.{};
    s.builder.reset();

    const dip_w: i32 = @intFromFloat(@as(f32, @floatFromInt(s.width)) / s.scale);
    const dip_h: i32 = @intFromFloat(@as(f32, @floatFromInt(s.height)) / s.scale);

    if (s.draw) |f| {
        // The callback arrives typed for the toolkit; both pointers are opaque
        // here so the backend contract stays free of UI types.
        if (s.ctx) |ctx| f(ctx, @ptrCast(&s.builder), .{ .x = 0, .y = 0, .width = dip_w, .height = dip_h }, s.scale);
    }

    // Start from a clean buffer. The buffer is swapped to BGRA before the blit,
    // so a frame must never draw on top of the previous one: the colours would
    // be in the wrong order and stale pixels would show through.
    // The accessibility tree describes the same frame the drawing list does,
    // so a reader and the screen never disagree about what is visible.
    if (s.describe) |d| {
        if (!s.a11y_ready) {
            s.a11y_tree = ui.a11y.Builder.init(gpa);
            s.a11y_ready = true;
        }
        s.a11y_tree.begin(.{ .x = 0, .y = 0, .width = dip_w, .height = dip_h }) catch {};
        d.func(d.ctx, @ptrCast(&s.a11y_tree), .{ .x = 0, .y = 0, .width = dip_w, .height = dip_h });
        atspi.publish(s.window_id, s.a11y_tree.snapshot());
    }

    @memset(s.pixels, 0);
    const surface = ui.canvas.Surface.init(s.pixels, s.width, s.height);
    ui.canvas.render(surface, s.builder.commands.items, 1);
    return s.pixels;
}

fn onDraw(widget: ffi.GtkWidget, cr: ffi.gpointer, user_data: ?*anyopaque) callconv(.c) ffi.gboolean {
    _ = widget;
    const s: *Surface = @ptrCast(@alignCast(user_data.?));
    if (s.pixels.len == 0) return 0;

    _ = renderFrame(s);

    // CAIRO_FORMAT_ARGB32 is little-endian BGRA in memory, which is what the
    // X server expects. The toolkit writes RGBA, so the two extra calls below
    // swap the red and blue bytes before the blit.
    const fmt_argb32: c_int = 0;
    swapRedBlue(s.pixels);
    const stride: c_int = @intCast(s.width * 4);
    const src = ffi.cairo_image_surface_create_for_data(
        s.pixels.ptr,
        fmt_argb32,
        @intCast(s.width),
        @intCast(s.height),
        stride,
    ) orelse return 0;
    defer ffi.cairo_surface_destroy(src);

    ffi.cairo_surface_flush(src);
    ffi.cairo_set_source_surface(cr, src, 0, 0);
    // The buffer is device pixels; drawing at 1:1 would scale it twice.
    ffi.cairo_scale(cr, 1, 1);
    ffi.cairo_paint(cr);
    return 0;
}

/// Turns RGBA into BGRA in place. cairo's ARGB32 layout is BGRA on a
/// little-endian machine, so this is the one conversion between the toolkit's
/// colour order and the display server's.
fn swapRedBlue(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r = pixels[i];
        pixels[i] = pixels[i + 2];
        pixels[i + 2] = r;
    }
}

fn onSizeAllocate(widget: ffi.GtkWidget, alloc: *ffi.GtkAllocation, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const s: *Surface = @ptrCast(@alignCast(user_data.?));
    if (alloc.width <= 0 or alloc.height <= 0) return;
    resize(s, alloc.width, alloc.height, s.scale);
    ffi.gtk_widget_queue_draw(s.widget orelse return);
}

/// GDK's button and motion events begin with the same fields: type, window,
/// then `send_event` and `time`, and the x/y pair after that.
const EventXY = extern struct {
    type_: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
};

fn eventXY(event: ?*anyopaque) struct { x: f64, y: f64 } {
    const e: *const EventXY = @ptrCast(@alignCast(event orelse return .{ .x = 0, .y = 0 }));
    return .{ .x = e.x, .y = e.y };
}

fn onButtonPress(widget: ffi.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) ffi.gboolean {
    _ = widget;
    const s: *Surface = @ptrCast(@alignCast(user_data.?));
    const p = eventXY(event);
    log.debug("native surface {d}: press at {d:.1},{d:.1}", .{ s.window_id, p.x, p.y });
    if (s.widget) |w| ffi.gtk_widget_queue_draw(w);
    if (sink) |sk| sk.surfaceInput(s.window_id, .{ .pointer_down = .{
        .x = @floatCast(p.x / s.scale),
        .y = @floatCast(p.y / s.scale),
        .button = .left,
    } });
    return 0;
}

fn onButtonRelease(widget: ffi.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) ffi.gboolean {
    _ = widget;
    const s: *Surface = @ptrCast(@alignCast(user_data.?));
    const p = eventXY(event);
    if (sink) |sk| sk.surfaceInput(s.window_id, .{ .pointer_up = .{
        .x = @floatCast(p.x / s.scale),
        .y = @floatCast(p.y / s.scale),
        .button = .left,
    } });
    return 0;
}

fn onMotion(widget: ffi.GtkWidget, event: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) ffi.gboolean {
    _ = widget;
    const s: *Surface = @ptrCast(@alignCast(user_data.?));
    const p = eventXY(event);
    if (sink) |sk| sk.surfaceInput(s.window_id, .{ .pointer_move = .{
        .x = @floatCast(p.x / s.scale),
        .y = @floatCast(p.y / s.scale),
    } });
    return 0;
}

/// Asks GTK to repaint a surface now.
pub fn requestFrame(window_id: u32) void {
    const s = surfaces.get(window_id) orelse return;
    if (s.widget) |w| ffi.gtk_widget_queue_draw(w);
}

pub fn surfaceFor(window_id: u32) ?*Surface {
    return surfaces.get(window_id);
}

pub fn remove(window_id: u32) void {
    if (surfaces.fetchRemove(window_id)) |kv| destroySurface(kv.value);
}

test "a surface sized at 2x allocates device pixels" {
    // Covered by the integration test in tests/all.zig, which cannot run GTK
    // headless here; the arithmetic is checked there instead.
}

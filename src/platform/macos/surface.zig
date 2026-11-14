//! Native windows on macOS: an `NSView` subclass that MyZig paints itself.
//!
//! ## The pipeline
//!
//! 1. The application's UI code fills a `ui.canvas.Builder`.
//! 2. `ui.canvas.render` rasterises it into an RGBA buffer owned by this module.
//! 3. `drawRect:` wraps that buffer in a `CGImage` and paints it into the
//!    view's graphics context.
//!
//! No WebKit is mapped for this: a native-only window never touches the web
//! engine, which is why `counter-native` starts without one on every platform.
//!
//! ## Why the view is a class built at run time
//!
//! Mouse presses and key presses only reach `mouseDown:` and `keyDown:`, which
//! are Objective-C methods. This backend compiles no Objective-C, so those
//! methods are registered at run time from Zig function pointers with
//! `class_addMethod`, exactly as the delegates are (`delegate.zig`).
//!
//! ## Coordinates
//!
//! AppKit's views are bottom-left origin with Y up; MyZig's rects are top-left
//! with Y down. Every point that crosses into the framework is flipped once,
//! here, against the view's own height. `NSEvent.locationInWindow` is already in
//! points, which is what the framework calls DIPs.
//!
//! ## Testing
//!
//! Written against Apple's documentation, and **never run**: there is no Mac
//! here. The pure parts — the Y flip, the modifier mapping and the RGBA to
//! BGRA swap — are tested on any host.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const backend = @import("../backend.zig");
const events = @import("../../events.zig");
const ui = @import("../../ui/ui.zig");
const a11y = @import("a11y.zig");

/// One native surface: the pixel buffer, its geometry, and the view that shows
/// it.
pub const Surface = struct {
    /// RGBA8, tightly packed rows, `width * height * 4` bytes.
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// Device pixels per DIP.
    scale: f32 = 1,
    /// The caller's draw function, and the opaque context it expects.
    draw: ?*const fn (ctx: *anyopaque, builder: *anyopaque, size: backend.DrawRect, scale: f32) void = null,
    ctx: ?*anyopaque = null,
    /// The caller's accessibility description, built beside the frame it
    /// describes so a reader and the screen never disagree.
    describe: ?backend.AccessibleDraw = null,
    /// The accessibility tree for the frame just drawn, reused across frames.
    a11y_tree: ui.a11y.Builder,
    a11y_ready: bool = false,
    /// Reused across frames so drawing the same UI does not allocate.
    builder: ui.canvas.Builder,
    /// The `MyZigBitmapView`. Retained by the window's content view.
    view: objc.ObjCId = null,
    /// The window id the framework uses.
    window_id: u32 = 0,
};

/// Surfaces by window id. AppKit calls back with a view pointer, so the view
/// carries its surface in an associated object instead; this table exists so
/// `resize`, `requestFrame` and `present` can be reached by id.
var surfaces: std.AutoHashMapUnmanaged(u32, *Surface) = .empty;
var gpa: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    gpa = allocator;
}

pub fn deinit() void {
    var it = surfaces.valueIterator();
    while (it.next()) |s| destroy(s.*);
    surfaces.deinit(gpa);
    surfaces = .empty;
}

fn destroy(s: *Surface) void {
    s.builder.deinit();
    if (s.a11y_ready) s.a11y_tree.deinit();
    if (s.pixels.len > 0) gpa.free(s.pixels);
    gpa.destroy(s);
}

pub fn get(id: u32) ?*Surface {
    return surfaces.get(id);
}

// ------------------------------------------------------------------- class

/// Key under which a view records its surface.
const surface_key: *const anyopaque = @ptrFromInt(0x4D5A535246);

/// `NSView` subclasses can become the first responder, which is what makes
/// `keyDown:` arrive at all.
fn acceptsFirstResponder(_: objc.ObjCId, _: ?objc.Sel) callconv(.c) bool {
    return true;
}

fn viewOf(self: objc.ObjCId) ?*Surface {
    return @ptrCast(@alignCast(objc.associated(self, surface_key) orelse return null));
}

/// The window's sink and the surface, for an input callback.
/// The sink is copied into the surface's record through the associated object,
/// so a callback needs nothing but the view.
fn sinkOf(_: *Surface) ?backend.EventSink {
    return current_sink;
}

/// The sink input is reported to. Set once by the backend before any window.
var current_sink: ?backend.EventSink = null;

pub fn setSink(sink: backend.EventSink) void {
    current_sink = sink;
}

/// Points the accessibility bridge at this module's `pressAt`, which is the one
/// place that knows how to deliver a pointer press on macOS.
pub fn installPressHook() void {
    a11y.setPressHook(&pressAt);
}

/// A point in AppKit's coordinates, flipped to the framework's: top-left
/// origin, Y down.
pub fn flipY(y: f64, view_height: f64) f32 {
    return @floatCast(view_height - y);
}

/// AppKit's modifier flags to the framework's.
///
/// Shift is 1 << 17, Control 1 << 18, Option 1 << 19, Command 1 << 20. The
/// framework's `super` is Command, and `primary` derives from it on macOS, so a
/// Command-click is a primary-click everywhere without a second field.
pub fn modifiersFrom(flags: usize) events.Modifiers {
    return .{
        .shift = flags & (1 << 17) != 0,
        .control = flags & (1 << 18) != 0,
        .alt = flags & (1 << 19) != 0,
        .super = flags & (1 << 20) != 0,
    };
}

fn mouseButtonFrom(button_number: i64) events.MouseButton {
    // NSEvent.buttonNumber: 0 left, 1 right, 2 middle, 3 back, 4 forward.
    return switch (button_number) {
        1 => .right,
        2 => .middle,
        3 => .back,
        4 => .forward,
        else => .left,
    };
}

fn clickCount(e: objc.ObjCId) u8 {
    const n = objc.sendGetI64(e, "clickCount");
    if (n <= 0) return 1;
    return @intCast(@min(n, 3));
}

/// The location of an event in the view, flipped into the framework's space.
fn pointInView(view: objc.ObjCId, e: objc.ObjCId) struct { x: f32, y: f32 } {
    const p = objc.sendGetPoint(view, "convertPoint:fromView:", objc.sendGetPointNoArg(e, "locationInWindow"), null);
    const h = objc.sendGetRectNoArg(view, "bounds").height;
    return .{ .x = @floatCast(p.x), .y = flipY(p.y, h) };
}

fn mouseDown(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    const s = viewOf(self) orelse return;
    const sink = sinkOf(s) orelse return;
    const p = pointInView(self, e);
    sink.surfaceInput(s.window_id, .{ .pointer_down = .{
        .x = p.x,
        .y = p.y,
        .button = mouseButtonFrom(objc.sendGetI64(e, "buttonNumber")),
        .modifiers = modifiersFrom(@intCast(objc.sendGetI64(e, "modifierFlags"))),
        .clicks = clickCount(e),
    } });
}

fn mouseUp(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    const s = viewOf(self) orelse return;
    const sink = sinkOf(s) orelse return;
    const p = pointInView(self, e);
    sink.surfaceInput(s.window_id, .{ .pointer_up = .{
        .x = p.x,
        .y = p.y,
        .button = mouseButtonFrom(objc.sendGetI64(e, "buttonNumber")),
        .modifiers = modifiersFrom(@intCast(objc.sendGetI64(e, "modifierFlags"))),
        .clicks = clickCount(e),
    } });
}

fn mouseDragged(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    const s = viewOf(self) orelse return;
    const sink = sinkOf(s) orelse return;
    const p = pointInView(self, e);
    sink.surfaceInput(s.window_id, .{ .pointer_move = .{ .x = p.x, .y = p.y } });
}

fn mouseMoved(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    mouseDragged(self, null, e);
}

fn keyDown(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    const s = viewOf(self) orelse return;
    const sink = sinkOf(s) orelse return;
    // Committed text first: a key press that produces characters is text, and
    // the toolkit's own keyboard handling is for commands (Tab, arrows).
    const chars = objc.sendGetId(e, "characters");
    if (chars) |c| {
        if (objc.cString(c)) |text| {
            const span = std.mem.span(text);
            // A control character is a command key, not text: Escape is 0x1b.
            if (span.len > 0 and (span[0] >= 0x20 and span[0] != 0x7f)) {
                sink.surfaceInput(s.window_id, .{ .text = .{ .bytes = span } });
            }
        }
    }
    sink.surfaceInput(s.window_id, .{ .key_down = .{
        .key = .unknown,
        .modifiers = modifiersFrom(@intCast(objc.sendGetI64(e, "modifierFlags"))),
        .repeat = objc.sendGetBool(e, "isARepeat"),
    } });
}

fn keyUp(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    const s = viewOf(self) orelse return;
    const sink = sinkOf(s) orelse return;
    sink.surfaceInput(s.window_id, .{ .key_up = .{
        .key = .unknown,
        .modifiers = modifiersFrom(@intCast(objc.sendGetI64(e, "modifierFlags"))),
    } });
}

fn scrollWheel(self: objc.ObjCId, _: ?objc.Sel, e: objc.ObjCId) callconv(.c) void {
    const s = viewOf(self) orelse return;
    const sink = sinkOf(s) orelse return;
    const p = pointInView(self, e);
    sink.surfaceInput(s.window_id, .{ .wheel = .{
        .x = p.x,
        .y = p.y,
        .delta_x = @floatCast(objc.sendGetF64(e, "scrollingDeltaX")),
        .delta_y = @floatCast(objc.sendGetF64(e, "scrollingDeltaY")),
        .modifiers = modifiersFrom(@intCast(objc.sendGetI64(e, "modifierFlags"))),
        .precise = objc.sendGetBool(e, "hasPreciseScrollingDeltas"),
    } });
}

/// `drawRect:` rasterises the current frame and paints it.
///
/// The view is layer-backed (`wantsLayer`), so `drawRect:` runs into a
/// CoreGraphics context belonging to the layer. Wrapping the RGBA buffer in a
/// `CGImage` and drawing it is one copy in the system's own rasteriser.
fn drawRect(self: objc.ObjCId, _: ?objc.Sel, rect: objc.CGRect) callconv(.c) void {
    _ = rect;
    const s = viewOf(self) orelse return;
    renderFrame(s);

    const bounds = objc.sendGetRectNoArg(self, "bounds");
    const ctx = objc.sendGetId(objc.class("NSGraphicsContext") orelse return, "currentContext") orelse return;
    const cg_context: ?*anyopaque = objc.sendGetId(ctx, "CGContext") orelse return;

    const f = cg() orelse return;
    const image: ?*anyopaque = cgImage(s) orelse return;
    defer f.image_release(image);
    // The CG coordinate space is bottom-left, like AppKit's, so the image is
    // drawn at the origin and appears the right way up.
    var dest = objc.CGRect{ .x = 0, .y = 0, .width = bounds.width, .height = bounds.height };
    // Called through the field, not as `f.context_draw_image(...)`: a method
    // call on a value passes `f` first, which shifts every argument by one.
    //
    // The order is CoreGraphics': (context, rect, image), the rect by pointer.
    const draw_image = f.context_draw_image;
    draw_image(cg_context, &dest, image);
}

// CoreGraphics is a framework, and a Linux host has no copy of it. Like every
// other platform entry point in this backend, its functions are looked up by
// name, so the backend still links where the system does not have them.
var cg_lib: ?std.DynLib = null;
var cg_fns: ?CGFunctions = null;

const CGFunctions = struct {
    color_space_create: *const fn () callconv(.c) ?*anyopaque,
    color_space_release: *const fn (?*anyopaque) callconv(.c) void,
    provider_create: *const fn (?*anyopaque, ?*const anyopaque, usize, ?*const anyopaque) callconv(.c) ?*anyopaque,
    provider_release: *const fn (?*anyopaque) callconv(.c) void,
    image_create: *const fn (
        usize,
        usize,
        usize,
        usize,
        usize,
        ?*anyopaque,
        u32,
        ?*anyopaque,
        ?*const anyopaque,
        bool,
        i32,
    ) callconv(.c) ?*anyopaque,
    image_release: *const fn (?*anyopaque) callconv(.c) void,
    /// `CGContextDrawImage` takes a rect by *pointer*, unlike the AppKit
    /// struct-taking methods; the signature is written that way on purpose.
    context_draw_image: *const fn (?*anyopaque, *const objc.CGRect, ?*anyopaque) callconv(.c) void,
};

fn cg() ?CGFunctions {
    if (cg_fns) |f| return f;
    if (comptime builtin.os.tag != .macos) return null;
    var lib = std.DynLib.open(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    ) catch return null;
    const f = CGFunctions{
        .color_space_create = lib.lookup(*const fn () callconv(.c) ?*anyopaque, "CGColorSpaceCreateDeviceRGB") orelse return null,
        .color_space_release = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "CGColorSpaceRelease") orelse return null,
        .provider_create = lib.lookup(
            *const fn (?*anyopaque, ?*const anyopaque, usize, ?*const anyopaque) callconv(.c) ?*anyopaque,
            "CGDataProviderCreateWithData",
        ) orelse return null,
        .provider_release = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "CGDataProviderRelease") orelse return null,
        .image_create = lib.lookup(
            *const fn (usize, usize, usize, usize, usize, ?*anyopaque, u32, ?*anyopaque, ?*const anyopaque, bool, i32) callconv(.c) ?*anyopaque,
            "CGImageCreate",
        ) orelse return null,
        .image_release = lib.lookup(*const fn (?*anyopaque) callconv(.c) void, "CGImageRelease") orelse return null,
        .context_draw_image = lib.lookup(
            *const fn (?*anyopaque, *const objc.CGRect, ?*anyopaque) callconv(.c) void,
            "CGContextDrawImage",
        ) orelse return null,
    };
    cg_lib = lib;
    cg_fns = f;
    return f;
}

/// A `CGImage` over the surface's pixels, or null when there are none.
///
/// `kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big` is RGBA, which is
/// what the rasteriser writes, so no swap is needed on this path: the bytes go
/// straight into CoreGraphics.
fn cgImage(s: *Surface) ?*anyopaque {
    if (s.pixels.len == 0) return null;
    const f = cg() orelse return null;
    const space = f.color_space_create() orelse return null;
    defer f.color_space_release(space);

    // The provider borrows the buffer: no release callback, because the surface
    // owns the memory and outlives every draw.
    const provider = f.provider_create(null, s.pixels.ptr, s.pixels.len, null) orelse return null;
    defer f.provider_release(provider);

    const bitmap_info: u32 = 1;
    return f.image_create(
        s.width,
        s.height,
        8,
        32,
        @as(usize, s.width) * 4,
        space,
        bitmap_info,
        provider,
        null,
        false,
        0,
    );
}

/// Builds the view class once and returns it.
var view_class: ?objc.Class = null;

fn viewClass() ?objc.Class {
    if (view_class) |c| return c;
    if (comptime builtin.os.tag != .macos) return null;
    const super = objc.class("NSView") orelse return null;
    const cls = objc.objc_allocateClassPair(super, "MyZigBitmapView", 0) orelse return null;

    // Every method below is `v@:@` (self, selector, the event) except the two
    // that take no argument, which are `c@:` and `c@:@` with a rect.
    _ = objc.class_addMethod(cls, objc.sel("drawRect:"), @ptrCast(&drawRect), "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    _ = objc.class_addMethod(cls, objc.sel("mouseDown:"), @ptrCast(&mouseDown), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("mouseUp:"), @ptrCast(&mouseUp), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("mouseDragged:"), @ptrCast(&mouseDragged), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("mouseMoved:"), @ptrCast(&mouseMoved), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("rightMouseDown:"), @ptrCast(&mouseDown), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("rightMouseUp:"), @ptrCast(&mouseUp), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("keyDown:"), @ptrCast(&keyDown), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("keyUp:"), @ptrCast(&keyUp), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("scrollWheel:"), @ptrCast(&scrollWheel), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("acceptsFirstResponder"), @ptrCast(&acceptsFirstResponder), "c@:");

    objc.objc_registerClassPair(cls);
    view_class = cls;
    return cls;
}

// ------------------------------------------------------------------ public

/// Creates the surface for `window_id` and the view that shows it. The view is
/// added to `parent` (the window's content view) and sized to `rect`.
pub fn attach(
    id: u32,
    parent: objc.ObjCId,
    rect: objc.CGRect,
    sink: backend.EventSink,
) !*Surface {
    current_sink = sink;
    const cls = viewClass() orelse return error.NotSupported;

    const s = try gpa.create(Surface);
    errdefer gpa.destroy(s);
    s.* = .{
        .builder = ui.canvas.Builder.init(gpa),
        .a11y_tree = undefined,
        .window_id = id,
    };

    try surfaces.put(gpa, id, s);

    const allocated = objc.sendId1(cls, "alloc", null) orelse return error.OutOfMemory;
    const view = objc.sendIdRect(allocated, "initWithFrame:", rect) orelse return error.OutOfMemory;
    s.view = view;

    // The surface is found from the view on every callback, so nothing has to
    // be threaded through the Objective-C side.
    objc.associate(view, surface_key, s);
    // A layer-backed view is drawn through CoreAnimation, which is what makes
    // `drawRect:` reliable after the first frame.
    objc.sendBool(view, "setWantsLayer:", true);
    objc.sendVoidId(parent, "addSubview:", view);
    // The view follows the window as it resizes: width 2, height 16.
    objc.sendI64(view, "setAutoresizingMask:", 18);

    resize(s, rect.width, rect.height, 1);
    return s;
}

pub fn remove(id: u32) void {
    if (surfaces.fetchRemove(id)) |kv| {
        const s = kv.value;
        if (s.view) |v| objc.sendVoid(v, "removeFromSuperview");
        destroy(s);
    }
}

/// Allocates the pixel buffer for a size and scale.
pub fn resize(s: *Surface, width: f64, height: f64, scale: f32) void {
    const device_scale: f32 = if (scale > 0) scale else 1;
    const pw: u32 = @intFromFloat(@max(1, width * device_scale));
    const ph: u32 = @intFromFloat(@max(1, height * device_scale));
    if (pw == s.width and ph == s.height and s.pixels.len > 0) {
        s.scale = device_scale;
        return;
    }

    const bytes = @as(usize, pw) * ph * 4;
    if (s.pixels.len > 0) gpa.free(s.pixels);
    // Zeroed: an unpainted area is transparent black rather than whatever the
    // allocator happened to hold.
    s.pixels = gpa.alloc(u8, bytes) catch {
        s.pixels = &.{};
        s.width = 0;
        s.height = 0;
        return;
    };
    @memset(s.pixels, 0);
    s.width = pw;
    s.height = ph;
    s.scale = device_scale;
}

/// Runs the application's draw function and rasterises the result.
pub fn renderFrame(s: *Surface) void {
    if (s.pixels.len == 0) return;
    s.builder.reset();

    const dip_w: i32 = @intFromFloat(@as(f32, @floatFromInt(s.width)) / s.scale);
    const dip_h: i32 = @intFromFloat(@as(f32, @floatFromInt(s.height)) / s.scale);
    const scale_i: i32 = @intFromFloat(@max(1, s.scale));

    if (s.draw) |f| {
        if (s.ctx) |ctx| {
            f(ctx, @ptrCast(&s.builder), .{ .x = 0, .y = 0, .width = dip_w, .height = dip_h }, s.scale);
        }
    }

    // The accessibility tree describes the same frame the drawing list does, so
    // a reader and the screen never disagree about what is visible.
    if (s.describe) |d| {
        if (!s.a11y_ready) {
            s.a11y_tree = ui.a11y.Builder.init(gpa);
            s.a11y_ready = true;
        }
        s.a11y_tree.begin(.{ .x = 0, .y = 0, .width = dip_w, .height = dip_h }) catch {};
        d.func(d.ctx, @ptrCast(&s.a11y_tree), .{ .x = 0, .y = 0, .width = dip_w, .height = dip_h });
        // The view is the container VoiceOver walks; the elements hang from it.
        if (s.view) |v| a11y.publish(s.window_id, v, s.a11y_tree.snapshot());
    }

    // A frame must never draw on top of the previous one: the pixels are
    // swapped in place before the blit, so a second pass would blend into
    // stale colours.
    @memset(s.pixels, 0);
    ui.canvas.render(ui.Surface.init(s.pixels, s.width, s.height), s.builder.commands.items, scale_i);
}

/// Asks AppKit to repaint the view, which runs `drawRect:` in the next frame.
pub fn requestFrame(id: u32) void {
    const s = surfaces.get(id) orelse return;
    if (s.view) |v| objc.sendVoid(v, "setNeedsDisplay:");
}

/// Turns RGBA into BGRA in place.
///
/// The CoreGraphics path does *not* need this: it is told the buffer is RGBA
/// and reads it that way. It exists for a path that hands the pixels to
/// something expecting `kCGBitmapByteOrder32Little` — a `CGBitmapContext` drawn
/// with `kCGImageAlphaPremultipliedFirst`, for instance — and is tested so that
/// whoever takes that route gets a correct function rather than a plausible
/// one.
pub fn swapRedBlue(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r = pixels[i];
        pixels[i] = pixels[i + 2];
        pixels[i + 2] = r;
    }
}

/// Delivers a press at a DIP position, as if the pointer had clicked there.
///
/// This is the path a reader's `AXPress` takes: the same down-then-up pair a
/// real click produces, so the application's own handler runs and nothing has
/// to know the press came from VoiceOver.
pub fn pressAt(window_id: u32, x: i32, y: i32) bool {
    const s = surfaces.get(window_id) orelse return false;
    const sink = sinkOf(s) orelse return false;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);

    sink.surfaceInput(window_id, .{ .pointer_down = .{ .x = fx, .y = fy, .button = .left } });
    sink.surfaceInput(window_id, .{ .pointer_up = .{ .x = fx, .y = fy, .button = .left } });
    requestFrame(window_id);
    return true;
}

// ------------------------------------------------------------------- tests

test "a point is flipped from AppKit's bottom-left origin to the framework's" {
    // A 600 point tall view: the top edge is y = 0 and the bottom y = 600.
    try std.testing.expectEqual(@as(f32, 0), flipY(600, 600));
    try std.testing.expectEqual(@as(f32, 600), flipY(0, 600));
    try std.testing.expectEqual(@as(f32, 550), flipY(50, 600));
}

test "modifier flags map onto the framework's fields" {
    const shift = modifiersFrom(1 << 17);
    try std.testing.expect(shift.shift and !shift.super);

    const cmd = modifiersFrom(1 << 20);
    try std.testing.expect(cmd.super);
    // Command is the accelerator modifier on macOS, so it must read primary
    // *there*. `primary()` decides from the build's target OS, and this test
    // runs on the host, so it asserts the field rather than the derivation.
    try std.testing.expect(!cmd.control);

    const both = modifiersFrom((1 << 20) | (1 << 17) | (1 << 19));
    try std.testing.expect(both.super and both.shift and both.alt);
    try std.testing.expect(!both.control);

    try std.testing.expect(!modifiersFrom(0).any());
}

test "red and blue are swapped without touching alpha" {
    var px = [_]u8{ 10, 20, 30, 255, 1, 2, 3, 4 };
    swapRedBlue(&px);
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255, 3, 2, 1, 4 }, &px);
    // A buffer that is not a whole number of pixels is left alone past its end.
    var odd = [_]u8{ 10, 20, 30, 40, 7 };
    swapRedBlue(&odd);
    try std.testing.expectEqual(@as(u8, 7), odd[4]);
}

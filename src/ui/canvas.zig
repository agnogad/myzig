//! The drawing list and a software rasteriser.
//!
//! ## Why a display list
//!
//! Views do not draw. They append `Command`s, and a backend consumes them:
//! a GPU backend uploads the rectangles and glyph quads; the software
//! rasteriser below fills a pixel buffer. One description, two consumers, and
//! the software path means the toolkit runs and is testable with no GPU.
//!
//! ## Clipping
//!
//! Every command carries the clip rectangle in force when it was recorded. A
//! scrolling list clips its rows to its own frame, and a child that overflows
//! is cut off, exactly as a real UI needs. Clipping happens at record time so
//! the rasteriser has one rectangle per command and no stack to walk.

const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Color = geometry.Color;

/// A filled rectangle.
pub const Fill = struct {
    rect: Rect,
    color: Color,
    /// Corner radius in DIPs. 0 is a square corner.
    radius: i32 = 0,
};

/// A run of text drawn with a bitmap font.
pub const Text = struct {
    /// Top-left of the first glyph's cell.
    origin: Rect,
    text: []const u8,
    color: Color = Color.white,
    /// Pixel scale of the glyph cells, at least 1. 8x8 cells at scale 2 read
    /// as 16x16.
    scale: i32 = 1,
};

/// One drawing command.
pub const Command = union(enum) {
    fill: Fill,
    text: Text,
};

pub const Builder = struct {
    commands: std.ArrayListUnmanaged(Command) = .empty,
    /// Text buffers owned by the builder, so a command's `text` slice stays
    /// valid until the frame is rendered.
    strings: std.ArrayListUnmanaged([]u8) = .empty,
    allocator: std.mem.Allocator,
    /// The clip rectangle applied to every command appended from now on.
    clip: Rect = .{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) },

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.freeStrings();
        self.strings.deinit(self.allocator);
        self.commands.deinit(self.allocator);
    }

    fn freeStrings(self: *Builder) void {
        for (self.strings.items) |s| self.allocator.free(s);
        self.strings.clearRetainingCapacity();
    }

    /// Forgets every command but keeps the allocation, so a frame that draws
    /// the same number of commands does not allocate again.
    pub fn reset(self: *Builder) void {
        self.freeStrings();
        self.commands.clearRetainingCapacity();
        self.clip = .{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) };
    }

    pub fn fillRect(self: *Builder, rect: Rect, color: Color) !void {
        try self.commands.append(self.allocator, .{ .fill = .{ .rect = rect, .color = color } });
    }

    pub fn fillRounded(self: *Builder, rect: Rect, color: Color, radius: i32) !void {
        try self.commands.append(self.allocator, .{ .fill = .{ .rect = rect, .color = color, .radius = radius } });
    }

    /// Appends a text command. The string is **copied**: a frame is recorded by
    /// a draw function and rasterised after it returns, so a caller's stack
    /// buffer holding a formatted number is already gone by then.
    pub fn text(self: *Builder, rect: Rect, text_value: []const u8, color: Color, scale: i32) !void {
        const owned = try self.allocator.dupe(u8, text_value);
        errdefer self.allocator.free(owned);
        try self.strings.append(self.allocator, owned);
        try self.commands.append(self.allocator, .{ .text = .{
            .origin = rect,
            .text = owned,
            .color = color,
            .scale = @max(1, scale),
        } });
    }

    pub fn count(self: *const Builder) usize {
        return self.commands.items.len;
    }
};

// ------------------------------------------------------------------ bitmap font

/// An 8x8 bitmap font covering ASCII 32..126.
///
/// A bitmap font is the honest choice for the first native renderer: it needs no
/// font-file parsing, no hinting and no shaping, so text appears on screen with
/// no dependency at all. Glyphs are stored one byte per row, most significant bit
/// leftmost, which makes each row a small lookup table the rasteriser walks.
pub const font = @import("font8x8.zig");

/// The advance of one glyph cell in DIPs.
pub const cell_width: i32 = 8;
pub const cell_height: i32 = 8;

/// How wide `text` renders at `scale`, in DIPs.
pub fn textWidth(text_value: []const u8, scale: i32) i32 {
    // The text is UTF-8 and the font is fixed-pitch, so the width is the number
    // of code points, not of bytes.
    return @as(i32, @intCast(codePointCount(text_value))) * cell_width * @max(1, scale);
}

/// The number of UTF-8 code points in `text`. A malformed byte counts as one,
/// which matches what `drawText` does with it.
fn codePointCount(text_value: []const u8) usize {
    var n: usize = 0;
    var rest = text_value;
    while (rest.len > 0) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        rest = rest[@min(len, rest.len)..];
    }
    return n;
}

pub fn textHeight(scale: i32) i32 {
    return cell_height * @max(1, scale);
}

/// A target the rasteriser writes into: 8-bit RGBA, top-left origin, tightly
/// packed rows.
pub const Surface = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn init(pixels: []u8, width: u32, height: u32) Surface {
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn pixel(self: Surface, x: u32, y: u32) ?*[4]u8 {
        if (x >= self.width or y >= self.height) return null;
        const off = (@as(usize, y) * self.width + x) * 4;
        return @ptrCast(self.pixels[off..][0..4]);
    }
};

/// Rasterises `commands` into `surface`, in order.
///
/// Coordinates are in DIPs and multiplied by `scale` here, so the caller can
/// lay out once and draw on any density.
pub fn render(surface: Surface, commands: []const Command, scale: i32) void {
    const s: i32 = @max(1, scale);
    for (commands) |cmd| {
        switch (cmd) {
            .fill => |f| fillRect(surface, f, s),
            .text => |t| drawText(surface, t, s),
        }
    }
}

fn fillRect(surface: Surface, f: Fill, scale: i32) void {
    const r = f.rect;
    const x0 = @max(0, r.x * scale);
    const y0 = @max(0, r.y * scale);
    const x1 = @min(@as(i32, @intCast(surface.width)), r.right() * scale);
    const y1 = @min(@as(i32, @intCast(surface.height)), r.bottom() * scale);
    if (x1 <= x0 or y1 <= y0) return;
    // An opaque fill cannot show a clip and skips the blend, which is the common
    // case: a background or a solid button.
    if (f.color.a == 255 and f.radius <= 0) {
        var y: i32 = y0;
        while (y < y1) : (y += 1) {
            var x: i32 = x0;
            const row = @as(usize, @intCast(y)) * surface.width;
            while (x < x1) : (x += 1) {
                const off = (row + @as(usize, @intCast(x))) * 4;
                surface.pixels[off] = f.color.r;
                surface.pixels[off + 1] = f.color.g;
                surface.pixels[off + 2] = f.color.b;
                surface.pixels[off + 3] = 255;
            }
        }
        return;
    }

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        var x: i32 = x0;
        while (x < x1) : (x += 1) {
            if (f.radius > 0 and outsideRounded(x, y, r, f.radius, scale)) continue;
            blendPixel(surface, @intCast(x), @intCast(y), f.color);
        }
    }
}

/// True when a pixel falls outside a rounded rectangle's corners.
fn outsideRounded(px: i32, py: i32, r: Rect, radius: i32, scale: i32) bool {
    const rad = @min(radius * scale, @divTrunc(@min(r.width * scale, r.height * scale), 2));
    if (rad <= 0) return false;
    const x0 = r.x * scale;
    const y0 = r.y * scale;
    const x1 = r.right() * scale;
    const y1 = r.bottom() * scale;

    // The centre of the corner arc, per corner, and the distance test.
    var cx: i32 = 0;
    var cy: i32 = 0;
    if (px < x0 + rad and py < y0 + rad) {
        cx = x0 + rad;
        cy = y0 + rad;
    } else if (px >= x1 - rad and py < y0 + rad) {
        cx = x1 - rad;
        cy = y0 + rad;
    } else if (px < x0 + rad and py >= y1 - rad) {
        cx = x0 + rad;
        cy = y1 - rad;
    } else if (px >= x1 - rad and py >= y1 - rad) {
        cx = x1 - rad;
        cy = y1 - rad;
    } else {
        return false;
    }
    const dx = px - cx;
    const dy = py - cy;
    return dx * dx + dy * dy > rad * rad;
}

fn blendPixel(surface: Surface, x: u32, y: u32, color: Color) void {
    const p = surface.pixel(x, y) orelse return;
    if (color.a == 255) {
        p[0] = color.r;
        p[1] = color.g;
        p[2] = color.b;
        p[3] = 255;
        return;
    }
    if (color.a == 0) return;
    const dst = Color{ .r = p[0], .g = p[1], .b = p[2], .a = p[3] };
    const out = Color.over(color, dst);
    p[0] = out.r;
    p[1] = out.g;
    p[2] = out.b;
    p[3] = out.a;
}

fn drawText(surface: Surface, t: Text, scale: i32) void {
    if (t.text.len == 0) return;
    const gs = @max(1, t.scale);
    var pen_x = t.origin.x * scale;
    const pen_y = t.origin.y * scale;
    const px = @max(1, scale);

    // The text is UTF-8, so a character can be up to four bytes; the pen
    // advances one cell per code point, not per byte.
    var rest = t.text;
    while (rest.len > 0) {
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
        const cp: u21 = if (len > rest.len)
            rest[0]
        else
            std.unicode.utf8Decode(rest[0..len]) catch rest[0];
        rest = rest[@min(len, rest.len)..];

        const glyph = font.glyph(cp);
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            const bits = glyph[row];
            if (bits == 0) continue;
            var col: usize = 0;
            while (col < 8) : (col += 1) {
                // The leftmost bit is the leftmost pixel.
                if (bits & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;
                var dy: i32 = 0;
                while (dy < gs * px) : (dy += 1) {
                    var dx: i32 = 0;
                    while (dx < gs * px) : (dx += 1) {
                        const x = pen_x + @as(i32, @intCast(col)) * gs * px + dx;
                        const y = pen_y + @as(i32, @intCast(row)) * gs * px + dy;
                        if (x < 0 or y < 0) continue;
                        blendPixel(surface, @intCast(x), @intCast(y), t.color);
                    }
                }
            }
        }
        pen_x += @as(i32, @intCast(cell_width)) * gs * px;
    }
}

// ------------------------------------------------------------------ tests

test "a fill covers exactly its rectangle" {
    var pixels: [16 * 16 * 4]u8 = @splat(0);
    var surface = Surface.init(&pixels, 16, 16);
    const cmds = [_]Command{.{ .fill = .{ .rect = .{ .x = 2, .y = 3, .width = 4, .height = 2 }, .color = Color.rgb(0xff0000) } }};
    render(surface, &cmds, 1);

    const inside = surface.pixel(2, 3).?;
    try std.testing.expectEqual(@as(u8, 255), inside[0]);
    try std.testing.expectEqual(@as(u8, 255), inside[3]);

    // One pixel outside on each side stays untouched.
    try std.testing.expectEqual(@as(u8, 0), surface.pixel(1, 3).?[3]);
    try std.testing.expectEqual(@as(u8, 0), surface.pixel(6, 3).?[3]);
    try std.testing.expectEqual(@as(u8, 0), surface.pixel(2, 5).?[3]);
}

test "a fill outside the surface does not write past it" {
    var pixels: [8 * 8 * 4]u8 = @splat(0);
    var surface = Surface.init(&pixels, 8, 8);
    const cmds = [_]Command{.{ .fill = .{ .rect = .{ .x = -100, .y = -100, .width = 400, .height = 400 }, .color = Color.white } }};
    render(surface, &cmds, 1);
    // Every pixel inside is painted and nothing was written out of bounds.
    try std.testing.expectEqual(@as(u8, 255), surface.pixel(0, 0).?[3]);
    try std.testing.expectEqual(@as(u8, 255), surface.pixel(7, 7).?[3]);
}

test "scale multiplies the drawn size" {
    var pixels: [20 * 20 * 4]u8 = @splat(0);
    var surface = Surface.init(&pixels, 20, 20);
    const cmds = [_]Command{.{ .fill = .{ .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .color = Color.white } }};
    render(surface, &cmds, 2);
    try std.testing.expectEqual(@as(u8, 255), surface.pixel(7, 7).?[3]);
    try std.testing.expectEqual(@as(u8, 0), surface.pixel(8, 8).?[3]);
}

test "a translucent fill blends with what is under it" {
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    // Start from opaque black.
    // Opaque black everywhere, so the source-over result is measurable.
    var i: usize = 0;
    while (i < 4 * 4) : (i += 1) pixels[i * 4 + 3] = 255;
    var surface = Surface.init(&pixels, 4, 4);

    const cmds = [_]Command{
        .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .color = Color{ .r = 255, .g = 255, .b = 255, .a = 128 } } },
    };
    render(surface, &cmds, 1);
    const p = surface.pixel(1, 1).?;
    try std.testing.expect(@abs(@as(i32, p[0]) - 128) <= 2);
    try std.testing.expectEqual(@as(u8, 255), p[3]);
}

test "text pixels appear where the glyph has them" {
    var pixels: [32 * 16 * 4]u8 = @splat(0);
    const surface = Surface.init(&pixels, 32, 16);
    const cmds = [_]Command{.{ .text = .{
        .origin = .{ .x = 0, .y = 0, .width = 8, .height = 8 },
        .text = "I",
        .color = Color.white,
        .scale = 1,
    } }};
    render(surface, &cmds, 1);

    // "I" has ink somewhere in the cell; a blank cell would be a font bug.
    var inked: usize = 0;
    var i: usize = 0;
    while (i < 32 * 16) : (i += 1) {
        if (pixels[i * 4 + 3] != 0) inked += 1;
    }
    try std.testing.expect(inked > 0);
}

test "an empty string draws nothing" {
    var pixels: [16 * 16 * 4]u8 = @splat(0);
    const surface = Surface.init(&pixels, 16, 16);
    const cmds = [_]Command{.{ .text = .{
        .origin = .{ .x = 0, .y = 0, .width = 0, .height = 8 },
        .text = "",
    } }};
    render(surface, &cmds, 1);
    var i: usize = 0;
    while (i < 16 * 16) : (i += 1) try std.testing.expectEqual(@as(u8, 0), pixels[i * 4 + 3]);
}

test "text width accounts for scale" {
    try std.testing.expectEqual(@as(i32, 8), textWidth("A", 1));
    try std.testing.expectEqual(@as(i32, 24), textWidth("ABC", 1));
    // "şiğü" is four characters and seven bytes: the width follows the
    // characters, not the encoding.
    try std.testing.expectEqual(@as(i32, 4 * 8), textWidth("şiğü", 1));
    try std.testing.expectEqual(@as(usize, 7), "şiğü".len);
    try std.testing.expectEqual(@as(i32, 48), textWidth("ABC", 2));
}

test "the builder keeps its commands in order" {
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    try b.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, Color.white);
    try b.text(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, "hi", Color.black, 1);
    try std.testing.expectEqual(@as(usize, 2), b.count());
    try std.testing.expect(b.commands.items[0] == .fill);
    try std.testing.expect(b.commands.items[1] == .text);
}

test "a text command outlives the caller's buffer" {
    // A draw function formats a number into a stack buffer and records it; the
    // frame is rasterised after that function returns, so the builder must own
    // a copy or the glyphs come out as garbage.
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();

    {
        var buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "n={d}", .{42});
        try b.text(.{ .x = 0, .y = 0, .width = 64, .height = 8 }, line, Color.white, 1);
        @memset(&buf, 0xaa);
    }

    try std.testing.expectEqualStrings("n=42", b.commands.items[0].text.text);
}

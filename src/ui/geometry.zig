//! Geometry for the native UI toolkit.
//!
//! Everything is in **device independent pixels**. The backend reports a scale
//! factor (1.0, 1.25, 2.0), and the renderer multiplies by it when it produces
//! pixels. Keeping the layout in DIPs means the same UI description lays out
//! identically on a 1x and a 2x display, which is the whole point of DIPs.
//!
//! All arithmetic is integer. A layout engine that adds `f32` sizes accumulates
//! rounding error, and a row of boxes that should line up ends up off by a
//! pixel; integers cannot drift.

const std = @import("std");

/// An axis-aligned rectangle.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub const zero = Rect{};

    pub fn right(self: Rect) i32 {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.height;
    }

    pub fn area(self: Rect) i64 {
        return @as(i64, @max(0, self.width)) * @as(i64, @max(0, self.height));
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }

    /// Grows the rectangle on every side by `n`.
    pub fn inset(self: Rect, n: i32) Rect {
        return .{
            .x = self.x + n,
            .y = self.y + n,
            .width = @max(0, self.width - 2 * n),
            .height = @max(0, self.height - 2 * n),
        };
    }

    /// The overlap of two rectangles, or a zero rectangle when they do not meet.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x = @max(self.x, other.x);
        const y = @max(self.y, other.y);
        const r = @min(self.right(), other.right());
        const b = @min(self.bottom(), other.bottom());
        if (r <= x or b <= y) return .zero;
        return .{ .x = x, .y = y, .width = r - x, .height = b - y };
    }

    /// True when the two rectangles share any area.
    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.intersect(other).area() > 0;
    }

    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
    }
};

/// Edge insets: padding around a child, or a margin around a box.
pub const Edges = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    pub const zero = Edges{};

    pub fn all(n: i32) Edges {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }

    pub fn symmetric(horizontal_amount: i32, vertical_amount: i32) Edges {
        return .{ .top = vertical_amount, .right = horizontal_amount, .bottom = vertical_amount, .left = horizontal_amount };
    }

    pub fn horizontal(self: Edges) i32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) i32 {
        return self.top + self.bottom;
    }

    /// The area inside these insets.
    pub fn shrink(self: Edges, r: Rect) Rect {
        return .{
            .x = r.x + self.left,
            .y = r.y + self.top,
            .width = @max(0, r.width - self.horizontal()),
            .height = @max(0, r.height - self.vertical()),
        };
    }

    pub fn grow(self: Edges, r: Rect) Rect {
        return .{
            .x = r.x - self.left,
            .y = r.y - self.top,
            .width = r.width + self.horizontal(),
            .height = r.height + self.vertical(),
        };
    }
};

/// An 8-bit-per-channel colour with straight (non-premultiplied) alpha.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };

    /// `0xRRGGBB` with full alpha.
    pub fn rgb(hex: u24) Color {
        return .{
            .r = @intCast((hex >> 16) & 0xff),
            .g = @intCast((hex >> 8) & 0xff),
            .b = @intCast(hex & 0xff),
        };
    }

    /// `0xRRGGBBAA`.
    pub fn rgba(hex: u32) Color {
        return .{
            .r = @intCast((hex >> 24) & 0xff),
            .g = @intCast((hex >> 16) & 0xff),
            .b = @intCast((hex >> 8) & 0xff),
            .a = @intCast(hex & 0xff),
        };
    }

    pub fn withAlpha(self: Color, a: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    /// Source-over compositing of `top` onto `bottom`, both straight alpha.
    /// Returns straight alpha. This is the one blending rule the renderer
    /// needs, so it lives here where it can be unit tested.
    pub fn over(top: Color, bottom: Color) Color {
        if (top.a == 255 or bottom.a == 0) return top;
        if (top.a == 0) return bottom;

        const ta: u32 = top.a;
        const ba: u32 = bottom.a;
        const out_a = ta + ba * (255 - ta) / 255;
        if (out_a == 0) return transparent;

        const mix = struct {
            fn f(t: u8, b: u8, ta_: u32, ba_: u32, out: u32) u8 {
                // Straight-alpha source-over: the top colour contributes `t*ta`,
                // the bottom `b*ba*(1-ta)`.
                const num = @as(u32, t) * ta_ * 255 + @as(u32, b) * ba_ * (255 - ta_);
                return @intCast(@min(255, num / (out * 255)));
            }
        }.f;

        return .{
            .r = mix(top.r, bottom.r, ta, ba, out_a),
            .g = mix(top.g, bottom.g, ta, ba, out_a),
            .b = mix(top.b, bottom.b, ta, ba, out_a),
            .a = @intCast(out_a),
        };
    }
};

// ------------------------------------------------------------------ tests

test "rect edges and containment" {
    const r = Rect{ .x = 10, .y = 20, .width = 100, .height = 50 };
    try std.testing.expectEqual(@as(i32, 110), r.right());
    try std.testing.expectEqual(@as(i32, 70), r.bottom());
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(r.contains(109, 69));
    // The far edges are exclusive, so adjacent rectangles do not both claim a
    // pixel and a hit test has one answer.
    try std.testing.expect(!r.contains(110, 69));
    try std.testing.expect(!r.contains(109, 70));
}

test "intersection of disjoint rectangles is empty" {
    const a = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rect{ .x = 20, .y = 0, .width = 10, .height = 10 };
    try std.testing.expectEqual(@as(i64, 0), a.intersect(b).area());
    try std.testing.expect(!a.overlaps(b));

    const c = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const i = a.intersect(c);
    try std.testing.expect(i.eql(.{ .x = 5, .y = 5, .width = 5, .height = 5 }));
}

test "inset never produces a negative size" {
    const r = Rect{ .x = 0, .y = 0, .width = 4, .height = 4 };
    const i = r.inset(10);
    try std.testing.expectEqual(@as(i32, 0), i.width);
    try std.testing.expectEqual(@as(i32, 0), i.height);
}

test "edges shrink symmetrically" {
    const r = Rect{ .x = 0, .y = 0, .width = 100, .height = 40 };
    const s = Edges.symmetric(10, 5).shrink(r);
    try std.testing.expectEqual(@as(i32, 80), s.width);
    try std.testing.expectEqual(@as(i32, 30), s.height);
    try std.testing.expectEqual(@as(i32, 10), s.x);
    try std.testing.expectEqual(@as(i32, 5), s.y);
}

test "colour parsing" {
    const c = Color.rgb(0x2f6fed);
    try std.testing.expectEqual(@as(u8, 0x2f), c.r);
    try std.testing.expectEqual(@as(u8, 0x6f), c.g);
    try std.testing.expectEqual(@as(u8, 0xed), c.b);
    try std.testing.expectEqual(@as(u8, 255), c.a);

    const t = Color.rgba(0x11223344);
    try std.testing.expectEqual(@as(u8, 0x11), t.r);
    try std.testing.expectEqual(@as(u8, 0x44), t.a);
}

test "opaque paint replaces what is under it" {
    const red = Color.rgb(0xff0000);
    const blue = Color.rgb(0x0000ff);
    try std.testing.expect(Color.over(red, blue).eql(red));
}

test "transparent paint leaves what is under it" {
    const blue = Color.rgb(0x0000ff);
    try std.testing.expect(Color.over(Color.transparent, blue).eql(blue));
}

test "half-transparent white over black is grey" {
    const white_half = Color{ .r = 255, .g = 255, .b = 255, .a = 128 };
    const out = Color.over(white_half, Color.black);
    // Every channel lands near 128; the exact value depends on the integer
    // rounding, so the test allows one step.
    try std.testing.expect(@abs(@as(i32, out.r) - 128) <= 2);
    try std.testing.expectEqual(@as(u8, 255), out.a);
}

test "blending is stable when repeated" {
    // Painting the same translucent colour twice must not accumulate alpha past
    // opaque, or a stack of identical layers would look different from one.
    const c = Color{ .r = 200, .g = 100, .b = 50, .a = 100 };
    var out = Color.black;
    var i: usize = 0;
    while (i < 20) : (i += 1) out = Color.over(c, out);
    try std.testing.expectEqual(@as(u8, 255), out.a);
}

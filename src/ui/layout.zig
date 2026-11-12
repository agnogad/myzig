//! Layout: turns a tree of views into rectangles.
//!
//! The model is flexbox's useful core: a box lays its children out in a row or
//! a column, with padding, spacing, a fixed or content-derived size, and a
//! grow factor that shares leftover space. That covers a toolbar, a sidebar, a
//! form and a list, which is what a desktop application actually builds.
//!
//! ## Why integer arithmetic
//!
//! Sizes are DIPs as `i32`. Summing `f32` sizes across a deep tree drifts, and a
//! row of equally-wide boxes ends up a pixel short or over. Integers distribute
//! exactly: `share` hands the remainder to the first boxes, so the total always
//! equals the available space.
//!
//! ## Two passes
//!
//! 1. **Measure** each child's size from its own content and constraints.
//! 2. **Arrange** the children, distributing leftover space by grow factor.
//!
//! Splitting the passes is what lets a text box report its own height before
//! anything is positioned.

const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Edges = geometry.Edges;

pub const Axis = enum { horizontal, vertical };

pub const Align = enum {
    /// Pack children at the start of the line.
    start,
    center,
    end,
    /// Stretch children across the cross axis.
    stretch,
    /// Share space between children; they keep their measured size.
    space_between,
};

/// A single layout node. Views own their nodes; the tree borrows style values.
pub const Node = struct {
    direction: Axis = .vertical,
    padding: Edges = .zero,
    margin: Edges = .zero,
    /// Gap between children along the main axis.
    spacing: i32 = 0,
    /// Alignment along the cross axis.
    cross_align: Align = .start,
    /// Alignment of the children as a group along the main axis.
    justify: Align = .start,

    /// Fixed size. A negative value means "measure from content".
    width: i32 = -1,
    height: i32 = -1,
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = std.math.maxInt(i32),
    max_height: i32 = std.math.maxInt(i32),
    /// Share of the leftover space in the parent's main axis. 0 means "no
    /// growth": the node keeps its measured size.
    grow: i32 = 0,

    /// The rectangle this node was given, filled in by `layout`.
    frame: Rect = .zero,

    /// Content size contributed by the view itself (text, an image). The
    /// layout takes the larger of this and the size its children need.
    intrinsic: Rect = .zero,
};

/// Calls `f` for each child of `parent`. The layout walks the tree through this
/// callback so it never needs to know how a view stores its children.
pub const ChildrenFn = *const fn (ctx: *anyopaque, parent: usize) []const usize;

/// A flat tree: node `i`'s children are given by `children(i)`.
pub const Tree = struct {
    nodes: []Node,
    /// The root node index.
    root: usize = 0,
    /// Returns the child indices of a node.
    child_of: *const fn (ctx: *const anyopaque, index: usize) []const usize,
    ctx: *const anyopaque,

    fn kids(self: Tree, i: usize) []const usize {
        return self.child_of(self.ctx, i);
    }
};

/// Lays `tree` out inside `bounds` and writes every node's `frame`.
pub fn layout(tree: Tree, bounds: Rect) void {
    arrange(tree, tree.root, bounds);
}

fn arrange(tree: Tree, index: usize, bounds: Rect) void {
    const node = &tree.nodes[index];
    node.frame = bounds;

    const inner = node.padding.shrink(bounds);
    const kids = tree.kids(index);
    if (kids.len == 0) return;

    const horizontal = node.direction == .horizontal;

    // Pass 1: measure in the main axis. A child with grow gets its share of
    // whatever is left after the fixed children, so a growing child next to a
    // fixed one does not push that one off the edge.
    var total_grow: i64 = 0;
    var fixed: i32 = 0;
    for (kids) |k| {
        const child = &tree.nodes[k];
        const measured = measure(child, node.direction, inner);
        if (child.grow > 0) {
            total_grow += child.grow;
            fixed += if (horizontal) 0 else measured.height;
        } else {
            fixed += if (horizontal) measured.width else measured.height;
            fixed += if (horizontal) child.margin.horizontal() else child.margin.vertical();
        }
    }
    const gaps: i32 = @as(i32, @intCast(kids.len - 1)) * node.spacing;
    const available = if (horizontal) inner.width else inner.height;
    const leftover = @max(0, available - fixed - gaps);

    // Pass 2: size and place each child.
    var cursor: i32 = if (horizontal) inner.x else inner.y;
    const main_len: i32 = if (horizontal) inner.width else inner.height;
    // The size the children occupy along the main axis.
    var total_main: i32 = fixed + gaps;
    for (kids) |k| {
        const child = &tree.nodes[k];
        if (child.grow > 0 and total_grow > 0) {
            total_main += @as(i32, @intCast(@divTrunc(@as(i64, leftover) * child.grow, total_grow)));
        }
    }
    switch (node.justify) {
        .center => cursor += @divTrunc(@max(0, main_len - total_main), 2),
        .end => cursor += @max(0, main_len - total_main),
        else => {},
    }

    // `space_between` puts the extra space between children, not around them.
    const between: i32 = if (node.justify == .space_between and kids.len > 1 and total_grow == 0)
        @divTrunc(leftover, @as(i32, @intCast(kids.len - 1)))
    else
        0;

    // The leftover space is split by grow factor. Integer division loses a
    // remainder, so the first `remainder` growing children get one extra pixel.
    // Their frames then add up to the parent exactly, with no gap at the edge.
    const remainder: i32 = if (total_grow > 0)
        @intCast(@mod(@as(i64, leftover), total_grow))
    else
        0;
    var grow_seen: i32 = 0;

    for (kids) |k| {
        const child = &tree.nodes[k];
        const measured = measure(child, node.direction, inner);

        var main_size: i32 = if (horizontal) measured.width else measured.height;
        if (child.grow > 0 and total_grow > 0) {
            main_size = @intCast(@divTrunc(@as(i64, leftover) * child.grow, total_grow));
            if (grow_seen < remainder) main_size += 1;
            grow_seen += 1;
        }

        var cross_size: i32 = if (horizontal) measured.height else measured.width;
        const cross_available = if (horizontal) inner.height else inner.width;
        if (node.cross_align == .stretch) cross_size = cross_available;

        const mb = if (horizontal) child.margin.left else child.margin.top;
        if (horizontal) {
            const h = cross_size + child.margin.vertical();
            const y = matchCross(node.cross_align, inner.y, cross_available, h) + child.margin.top;
            arrange(tree, k, .{
                .x = cursor + mb,
                .y = y,
                .width = main_size,
                .height = cross_size,
            });
        } else {
            const w = cross_size + child.margin.horizontal();
            const x = matchCross(node.cross_align, inner.x, cross_available, w) + child.margin.left;
            arrange(tree, k, .{
                .x = x,
                .y = cursor + mb,
                .width = cross_size,
                .height = main_size,
            });
        }

        cursor += main_size + mb + (if (horizontal) child.margin.right else child.margin.bottom);
        cursor += node.spacing + between;
    }
}

/// The measured size of a node, honouring its fixed size and constraints.
fn measure(node: *Node, direction: Axis, available: Rect) Rect {
    const horizontal = direction == .horizontal;

    var w = if (node.width >= 0) node.width else node.intrinsic.width;
    var h = if (node.height >= 0) node.height else node.intrinsic.height;

    // A growing child is measured as its intrinsic size; `arrange` replaces the
    // main axis with its share of the leftover space.
    if (horizontal) {
        w = clamp(w, node.min_width, node.max_width);
    } else {
        h = clamp(h, node.min_height, node.max_height);
    }
    // Bound by the space actually available, so a long label cannot overflow its
    // parent and paint outside the window.
    w = @min(w, available.width);
    h = @min(h, available.height);

    node.frame = .{ .x = node.frame.x, .y = node.frame.y, .width = w, .height = h };
    return .{ .x = 0, .y = 0, .width = w, .height = h };
}

fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

fn matchCross(mode: Align, start: i32, available: i32, size: i32) i32 {
    return switch (mode) {
        .start, .stretch, .space_between => start,
        .center => start + @divTrunc(available - size, 2),
        .end => start + (available - size),
    };
}

// ------------------------------------------------------------------ tests

/// A tree whose children are `const` slices, for tests and small apps.
pub const FlatTree = struct {
    nodes: []Node,
    kids_list: []const []const usize,

    pub fn childrenOf(ctx: *const anyopaque, index: usize) []const usize {
        const self: *const FlatTree = @ptrCast(@alignCast(ctx));
        if (index >= self.kids_list.len) return &.{};
        return self.kids_list[index];
    }
};

test "a column stacks its children" {
    var nodes = [_]Node{
        .{ .direction = .vertical, .height = 100 }, // 0: root
        .{}, // 1
        .{}, // 2
    };
    nodes[1].intrinsic = .{ .width = 10, .height = 20 };
    nodes[2].intrinsic = .{ .width = 10, .height = 30 };
    const kids = [_][]const usize{ &.{ 1, 2 }, &.{}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 0, .y = 0, .width = 100, .height = 100 });

    try std.testing.expectEqual(@as(i32, 0), nodes[1].frame.y);
    try std.testing.expectEqual(@as(i32, 20), nodes[2].frame.y);
}

test "spacing separates children" {
    var nodes = [_]Node{ .{}, .{}, .{} };
    nodes[1].intrinsic = .{ .width = 10, .height = 20 };
    nodes[2].intrinsic = .{ .width = 10, .height = 20 };
    nodes[0].spacing = 8;
    const kids = [_][]const usize{ &.{ 1, 2 }, &.{}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 0, .y = 0, .width = 50, .height = 100 });
    try std.testing.expectEqual(@as(i32, 28), nodes[2].frame.y);
}

test "padding positions the first child" {
    var nodes = [_]Node{ .{}, .{} };
    nodes[0].padding = Edges.all(12);
    nodes[1].intrinsic = .{ .width = 10, .height = 10 };
    const kids = [_][]const usize{ &.{1}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 5, .y = 5, .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(i32, 17), nodes[1].frame.x);
    try std.testing.expectEqual(@as(i32, 17), nodes[1].frame.y);
}

test "grow shares the leftover space exactly" {
    // Two growing children in 101 DIPs: the split must still add up to 101, so
    // one takes 51 and the other 50 rather than both taking 50 and leaving a gap.
    var nodes = [_]Node{ .{}, .{}, .{} };
    nodes[0].direction = .horizontal;
    nodes[1].grow = 1;
    nodes[2].grow = 1;
    const kids = [_][]const usize{ &.{ 1, 2 }, &.{}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 0, .y = 0, .width = 101, .height = 20 });
    // The odd pixel goes to the first child, so the row still totals 101.
    try std.testing.expectEqual(@as(i32, 51), nodes[1].frame.width);
    try std.testing.expectEqual(@as(i32, 50), nodes[2].frame.width);
    try std.testing.expectEqual(@as(i32, 101), nodes[1].frame.width + nodes[2].frame.width);
}

test "a fixed child keeps its size next to a growing one" {
    var nodes = [_]Node{ .{}, .{}, .{} };
    nodes[0].direction = .horizontal;
    nodes[1].width = 200;
    nodes[1].intrinsic = .{ .width = 200, .height = 10 };
    nodes[2].grow = 1;
    const kids = [_][]const usize{ &.{ 1, 2 }, &.{}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 0, .y = 0, .width = 500, .height = 20 });
    try std.testing.expectEqual(@as(i32, 200), nodes[1].frame.width);
    try std.testing.expectEqual(@as(i32, 300), nodes[2].frame.width);
}

test "stretch fills the cross axis" {
    var nodes = [_]Node{ .{}, .{} };
    nodes[0].cross_align = .stretch;
    nodes[0].direction = .horizontal;
    nodes[1].intrinsic = .{ .width = 10, .height = 10 };
    const kids = [_][]const usize{ &.{1}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 0, .y = 0, .width = 100, .height = 60 });
    try std.testing.expectEqual(@as(i32, 60), nodes[1].frame.height);
}

test "a child is never larger than its parent" {
    var nodes = [_]Node{ .{}, .{} };
    nodes[1].width = 10_000;
    nodes[1].height = 10_000;
    const kids = [_][]const usize{ &.{1}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    layout(tree, .{ .x = 0, .y = 0, .width = 80, .height = 40 });
    try std.testing.expect(nodes[1].frame.width <= 80);
    try std.testing.expect(nodes[1].frame.height <= 40);
}

test "center places a child in the middle" {
    var nodes = [_]Node{ .{}, .{} };
    nodes[0].cross_align = .center;
    nodes[1].intrinsic = .{ .width = 20, .height = 10 };
    const kids = [_][]const usize{ &.{1}, &.{} };
    var flat = FlatTree{ .nodes = &nodes, .kids_list = &kids };
    const tree = Tree{ .nodes = &nodes, .root = 0, .child_of = FlatTree.childrenOf, .ctx = &flat };

    // A column centres across the width, so the child's *x* moves.
    layout(tree, .{ .x = 0, .y = 0, .width = 100, .height = 20 });
    try std.testing.expectEqual(@as(i32, 40), nodes[1].frame.x);
    try std.testing.expectEqual(@as(i32, 0), nodes[1].frame.y);
}

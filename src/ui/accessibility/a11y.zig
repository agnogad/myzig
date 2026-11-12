//! Accessibility: what a screen reader is told about a native window.
//!
//! A native MyZig application draws glyphs into a pixel buffer. That is enough
//! for a sighted user and nothing at all for a screen reader, which sees a
//! window made of pixels with no structure in it. This module is the structure:
//! a tree of roles, names and states that the platform backend publishes.
//!
//! ## Shape
//!
//! The application describes its interface once per frame, the same way it
//! draws it, with `Builder`. The builder keeps a tree of `Node`s; a backend
//! reads the tree and hands it to the platform (AT-SPI over D-Bus on Linux,
//! UI Automation on Windows, `NSAccessibility` on macOS).
//!
//! ```zig
//! var a11y = accessibility.Builder.init(gpa);
//! try a11y.begin(.{ .width = 800, .height = 600 });
//! try a11y.role(.button, .{ .x = 16, .y = 72, .width = 120, .height = 32 }, .{
//!     .name = "Save",
//!     .description = "Write the document to disk",
//! });
//! ```
//!
//! ## Why a tree and not a flat list
//!
//! A screen reader announces "list, 3 items" and lets the user step inside. A
//! flat list of names cannot say that. The builder therefore keeps parents and
//! children, and a node's role decides what a reader does with it.
//!
//! ## Ownership
//!
//! `Builder` owns its nodes and the strings in them; `deinit` frees both. A
//! `Snapshot` borrowed from a builder is valid until the next `begin`, which is
//! the same lifetime rule as the drawing list — one frame.

const std = @import("std");
const geometry = @import("../geometry.zig");
const Rect = geometry.Rect;

/// What a node is. The set is the one a screen reader distinguishes; a role
/// that is not here is a `group`, which readers announce as structure only.
pub const Role = enum {
    /// The window itself. Exactly one per window, the root.
    window,
    /// A pressable control that does something.
    button,
    /// A pressable control with two states.
    toggle,
    /// Text the user can read but not change.
    label,
    /// Text the user can change.
    text_field,
    /// A set of mutually exclusive choices.
    radio_group,
    /// One choice in a radio group or a list.
    radio,
    /// A container that holds items.
    list,
    /// One item in a list.
    list_item,
    /// A container that holds other nodes and announces nothing itself.
    group,
    /// A value on a scale the user can move.
    slider,
    /// A bar showing progress the user cannot change.
    progress,
    /// A checkable entry.
    checkbox,
    /// A heading, which readers can jump between.
    heading,
    /// A horizontal or vertical divider.
    separator,
    /// An image with a description.
    image,

    ///
    /// AT-SPI asks for this string and a screen reader announces it, so the names
    /// are the ones the specification uses rather than the Zig tag names.
    /// The name a platform reports for this role. AT-SPI asks for this string
    /// and a screen reader announces it, so the names are the ones the
    /// specification uses rather than the Zig tag names.
    pub fn atspiName(self: Role) []const u8 {
        return switch (self) {
            .window => "frame",
            .button => "push button",
            .toggle => "toggle button",
            .label => "label",
            .text_field => "entry",
            .radio_group => "radio group",
            .radio => "radio button",
            .list => "list",
            .list_item => "list item",
            .group => "panel",
            .slider => "slider",
            .progress => "progress bar",
            .checkbox => "check box",
            .heading => "heading",
            .separator => "separator",
            .image => "image",
        };
    }
};

/// The states a node can be in. A reader announces these, and a backend maps
/// them to whatever the platform calls them.
pub const States = packed struct {
    /// The node can be pressed or typed into right now.
    enabled: bool = true,
    /// The user is looking at it.
    focused: bool = false,
    /// The value a toggle, checkbox or radio carries.
    checked: bool = false,
    /// A list item or radio is the chosen one.
    selected: bool = false,
    /// A text field refuses changes but can be read.
    readonly: bool = false,
    /// The node takes up space but is not shown.
    hidden: bool = false,
    /// The node cannot be reached by a reader's navigation.
    offscreen: bool = false,
    /// A busy region; readers may defer announcing changes inside it.
    busy: bool = false,
};

/// One node: a role, a place, and what to say about it.
pub const Node = struct {
    role: Role = .group,
    /// The rectangle in the surface's own pixels.
    bounds: Rect = .zero,
    /// What a reader says when it reaches this node. Borrowed from the builder.
    name: []const u8 = "",
    /// A longer explanation, announced on request.
    description: []const u8 = "",
    /// The current value, for a slider, progress bar or text field.
    value: []const u8 = "",
    states: States = .{},
    /// Where this node sits among its siblings, which is what "item 2 of 5"
    /// is built from.
    index_in_parent: u32 = 0,
    /// How many siblings there are, including this node.
    sibling_count: u32 = 0,
    /// The parent, or `null` for the root.
    parent: ?u32 = null,
    /// The first child, or `null`. Children are a linked list through
    /// `next_sibling`, which keeps the nodes in one array that can grow
    /// without invalidating ids.
    first_child: ?u32 = null,
    next_sibling: ?u32 = null,
    /// The node's own id, so a caller can keep a reference across frames.
    id: u32 = 0,
    /// What a reader can do to this node, in the order a reader offers it.
    actions: []const Action = &.{},
};

/// Something an accessibility client can ask a node to do.
///
/// An action is published because a screen reader drives an interface through
/// it: without one a reader can find a button and read its label but can never
/// press it, which leaves the whole interface unusable without a mouse.
pub const Action = struct {
    /// What a reader shows. AT-SPI calls the first one the node's action.
    name: []const u8,
    /// How the application receives it: the same number a pointer press at the
    /// node's centre would arrive with.
    kind: Kind,
};

pub const Kind = enum {
    /// A press: the button's own handler runs.
    press,
    /// Focus without pressing, for a text field.
    focus,
    /// A vertical step, for a slider.
    increment,
    decrement,
};

/// A read-only view of a finished tree.
pub const Snapshot = struct {
    nodes: []const Node,
    /// The root, always node 0 when the tree is not empty.
    root: ?u32 = null,

    pub fn get(self: Snapshot, id: u32) ?*const Node {
        if (id >= self.nodes.len) return null;
        return &self.nodes[id];
    }

    pub fn len(self: Snapshot) usize {
        return self.nodes.len;
    }
};

/// Builds one frame's tree.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    /// The strings the nodes point at, freed together at `begin`.
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The action tables, freed together with the strings.
    action_tables: std.ArrayListUnmanaged([]Action) = .empty,
    /// The node being filled, or `null` at the root.
    open: ?u32 = null,
    /// Whether `begin` has been called for this frame.
    started: bool = false,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Builder) void {
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.deinit(self.gpa);
        for (self.action_tables.items) |t| self.gpa.free(t);
        self.action_tables.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
    }

    /// Starts a frame. Every node from the last frame is dropped, because the
    /// tree describes what is on screen now.
    pub fn begin(self: *Builder, root_bounds: Rect) !void {
        self.clear();
        const id = try self.push();
        self.nodes.items[id].role = .window;
        self.nodes.items[id].bounds = root_bounds;
        // The root stays open so a caller can add to it without naming it,
        // which is what makes `begin` then `leaf` the whole API for a flat
        // window.
        self.open = id;
        self.started = true;
    }

    fn clear(self: *Builder) void {
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.clearRetainingCapacity();
        for (self.action_tables.items) |t| self.gpa.free(t);
        self.action_tables.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.open = null;
        self.started = false;
    }

    fn push(self: *Builder) !u32 {
        const id: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{ .id = id });
        return id;
    }

    /// Adds a node under the currently open one and leaves it open, so its
    /// children can be added next.
    pub fn beginNode(self: *Builder, role: Role, bounds: Rect) !u32 {
        // The parent is looked up *after* the push: `append` can move the
        // array, so a pointer taken before it would dangle. That is what made
        // the first version lose every child of every node.
        const parent = self.open;
        const id = try self.push();
        self.nodes.items[id].role = role;
        self.nodes.items[id].bounds = bounds;

        if (parent) |parent_id| {
            const p = &self.nodes.items[parent_id];
            // Append to the parent's child list, which keeps siblings in the
            // order the application added them.
            if (p.first_child) |first| {
                var last = first;
                while (self.nodes.items[last].next_sibling) |next| last = next;
                self.nodes.items[last].next_sibling = id;
            } else {
                p.first_child = id;
            }
            self.nodes.items[id].parent = parent_id;
            self.nodes.items[id].index_in_parent = p.sibling_count;
            p.sibling_count += 1;
        }
        self.open = id;
        return id;
    }

    /// Closes the node last opened by `beginNode`, so the next one is its
    /// sibling. Closing the root does nothing.
    pub fn endNode(self: *Builder) void {
        const current = self.open orelse return;
        const parent = self.nodes.items[current].parent orelse return;
        self.open = parent;
    }

    /// Adds a single node with no children under the open one.
    pub fn leaf(self: *Builder, role: Role, bounds: Rect, name: []const u8) !u32 {
        const id = try self.beginNode(role, bounds);
        try self.setName(id, name);
        self.endNode();
        return id;
    }

    /// Sets the name a reader announces. The string is copied.
    pub fn setName(self: *Builder, id: u32, text: []const u8) !void {
        if (id >= self.nodes.items.len) return;
        const copy = try self.gpa.dupe(u8, text);
        try self.strings.append(self.gpa, copy);
        self.nodes.items[id].name = copy;
    }

    pub fn setDescription(self: *Builder, id: u32, text: []const u8) !void {
        if (id >= self.nodes.items.len) return;
        const copy = try self.gpa.dupe(u8, text);
        try self.strings.append(self.gpa, copy);
        self.nodes.items[id].description = copy;
    }

    pub fn setValue(self: *Builder, id: u32, text: []const u8) !void {
        if (id >= self.nodes.items.len) return;
        const copy = try self.gpa.dupe(u8, text);
        try self.strings.append(self.gpa, copy);
        self.nodes.items[id].value = copy;
    }

    /// Records that a reader may press this node. The application's own press
    /// handler runs, as if the pointer had clicked the node's centre.
    pub fn setPressAction(self: *Builder, id: u32, label: []const u8) !void {
        if (id >= self.nodes.items.len) return;
        const copy = try self.gpa.dupe(u8, label);
        try self.strings.append(self.gpa, copy);
        const table = try self.gpa.alloc(Action, 1);
        try self.action_tables.append(self.gpa, table);
        table[0] = .{ .name = copy, .kind = .press };
        self.nodes.items[id].actions = table;
    }

    pub fn setStates(self: *Builder, id: u32, states: States) void {
        if (id >= self.nodes.items.len) return;
        self.nodes.items[id].states = states;
    }

    /// The finished tree. Valid until the next `begin` or `deinit`.
    pub fn snapshot(self: *const Builder) Snapshot {
        return .{
            .nodes = self.nodes.items,
            .root = if (self.nodes.items.len > 0) 0 else null,
        };
    }

    /// The node under a point, for hit testing from an accessibility client
    /// that asks "what is at this place".
    pub fn hitTest(self: *const Builder, x: i32, y: i32) ?u32 {
        // The deepest node wins, so children are searched before parents and a
        // button inside a group is reported rather than the group.
        if (!self.started) return null;
        return self.hitTestFrom(0, x, y);
    }

    fn hitTestFrom(self: *const Builder, id: u32, x: i32, y: i32) ?u32 {
        const n = &self.nodes.items[id];
        if (n.states.hidden) return null;
        if (!contains(n.bounds, x, y)) return null;

        var child = n.first_child;
        while (child) |c| {
            // Reverse order would report the topmost of overlapping siblings;
            // the drawing order is the same and a later sibling is drawn over
            // an earlier one, so the list is walked from the end.
            child = self.nodes.items[c].next_sibling;
        }

        // Walking forward is what reports a child that overlaps a later sibling
        // the way the drawing does not, so the children are collected and
        // searched in reverse.
        var count: u32 = 0;
        var c2 = n.first_child;
        while (c2) |cc| : (c2 = self.nodes.items[cc].next_sibling) count += 1;

        var remaining = count;
        while (remaining > 0) {
            remaining -= 1;
            var k: u32 = 0;
            var node = n.first_child;
            while (k < remaining) : (k += 1) node = self.nodes.items[node.?].next_sibling;
            if (node) |candidate| {
                if (self.hitTestFrom(candidate, x, y)) |hit| return hit;
            }
        }
        return id;
    }

    fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.width and y < r.y + r.height;
    }
};

test "a tree keeps parents and children in order" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.begin(.{ .width = 400, .height = 300 });
    const list = try b.beginNode(.list, .{ .x = 0, .y = 0, .width = 400, .height = 200 });
    _ = try b.leaf(.list_item, .{ .x = 0, .y = 0, .width = 400, .height = 40 }, "First");
    _ = try b.leaf(.list_item, .{ .x = 0, .y = 40, .width = 400, .height = 40 }, "Second");
    _ = try b.leaf(.list_item, .{ .x = 0, .y = 80, .width = 400, .height = 40 }, "Third");
    b.endNode();

    const snap = b.snapshot();
    try std.testing.expectEqual(@as(u32, 3), snap.get(list).?.sibling_count);

    // The three items are siblings under the list, in the order added.
    var it = snap.get(list).?.first_child;
    var names: [3][]const u8 = undefined;
    var i: usize = 0;
    while (it) |id| : (it = snap.get(id).?.next_sibling) {
        names[i] = snap.get(id).?.name;
        try std.testing.expectEqual(@as(u32, @intCast(i)), snap.get(id).?.index_in_parent);
        i += 1;
    }
    try std.testing.expectEqualStrings("First", names[0]);
    try std.testing.expectEqualStrings("Second", names[1]);
    try std.testing.expectEqualStrings("Third", names[2]);
}

test "a nested node is reachable only through its parent" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.begin(.{ .width = 400, .height = 300 });
    const group = try b.beginNode(.group, .{ .x = 16, .y = 16, .width = 200, .height = 100 });
    _ = try b.leaf(.button, .{ .x = 16, .y = 16, .width = 80, .height = 32 }, "Save");
    b.endNode();

    const snap = b.snapshot();
    const button = snap.get(snap.get(group).?.first_child.?).?;
    try std.testing.expectEqual(Role.button, button.role);
    try std.testing.expectEqual(@as(?u32, group), button.parent);
    try std.testing.expectEqualStrings("Save", button.name);
}

test "hit testing reports the deepest node under the point" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.begin(.{ .width = 400, .height = 300 });
    _ = try b.beginNode(.group, .{ .x = 0, .y = 0, .width = 400, .height = 300 });
    const button = try b.beginNode(.button, .{ .x = 16, .y = 16, .width = 80, .height = 32 });
    try b.setName(button, "Save");
    b.endNode();
    b.endNode();

    // Inside the button.
    try std.testing.expectEqual(@as(?u32, button), b.hitTest(20, 20));
    // Inside the group but outside the button.
    // The group, not the button.
    const hit = b.hitTest(200, 200).?;
    try std.testing.expect(hit != button);
    // Outside everything.
    try std.testing.expectEqual(@as(?u32, null), b.hitTest(500, 500));
}

test "a hidden node is not hit" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.begin(.{ .width = 400, .height = 300 });
    const button = try b.beginNode(.button, .{ .x = 16, .y = 16, .width = 80, .height = 32 });
    b.setStates(button, .{ .hidden = true });
    b.endNode();

    // A hidden node is skipped, so the point falls through to the root rather
    // than reporting a control the user cannot see.
    const hit = b.hitTest(20, 20).?;
    try std.testing.expect(hit != button);
    try std.testing.expectEqual(@as(?u32, 0), b.hitTest(20, 20));
    try std.testing.expectEqual(@as(?u32, 0), b.hitTest(300, 200));
}

test "an action is recorded and freed with the frame" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.begin(.{ .width = 100, .height = 100 });
    const id = try b.beginNode(.button, .{ .x = 10, .y = 10, .width = 40, .height = 20 });
    try b.setName(id, "Save");
    try b.setPressAction(id, "Save");
    b.endNode();

    const snap = b.snapshot();
    try std.testing.expectEqual(@as(usize, 1), snap.get(id).?.actions.len);
    try std.testing.expectEqualStrings("Save", snap.get(id).?.actions[0].name);
    try std.testing.expectEqual(Kind.press, snap.get(id).?.actions[0].kind);
}

test "a new frame frees the old strings" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.begin(.{ .width = 100, .height = 100 });
    _ = try b.leaf(.button, .{ .width = 10, .height = 10 }, "one");
    _ = try b.leaf(.button, .{ .width = 10, .height = 10 }, "two");
    try std.testing.expectEqual(@as(usize, 3), b.snapshot().len());

    // The second frame replaces the first entirely; if the strings leaked the
    // testing allocator would start failing here.
    try b.begin(.{ .width = 100, .height = 100 });
    try std.testing.expectEqual(@as(usize, 1), b.snapshot().len());
}

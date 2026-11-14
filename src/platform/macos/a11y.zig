//! Accessibility on macOS: the tree a VoiceOver user walks instead of looking.
//!
//! A native MyZig window is a pixel buffer, which is nothing at all to a screen
//! reader. The application describes its interface with
//! `ui.accessibility.Builder` once per frame, and this module turns that
//! description into `NSAccessibilityElement`s hung under the window.
//!
//! ## Two layers, because only one of them can be tested here
//!
//! * The **mapping** — which `NSAccessibility` role a MyZig role becomes, what
//!   a node's frame is in parent space, what an action is called — is pure Zig
//!   and has tests that run on Linux.
//! * The **object graph** — building the elements and attaching them — needs
//!   the real framework and has never been run, because there is no Mac here.
//!   Every such place says so.
//!
//! ## Frames
//!
//! `accessibilityFrameInParentSpace` is in the *parent's* coordinate space,
//! which for a view is its own bounds: origin bottom-left, Y up, points. MyZig
//! rects are top-left with Y down, so each frame is flipped against the view's
//! height exactly once — the same flip `surface.zig` does for input.
//!
//! ## Actions
//!
//! A reader does not click: it sends a press. That press runs the application's
//! own pointer handler at the node's centre, because a screen reader must reach
//! the same code a mouse reaches, not a parallel path that could drift.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const a11y = @import("../../ui/accessibility/a11y.zig");
const backend = @import("../backend.zig");

/// The `NSAccessibility` role for a MyZig role.
///
/// These are the string constants AppKit publishes (`NSAccessibilityButtonRole`
/// and its neighbours), written as the literals they are defined as. A role a
/// reader would not announce as itself maps to `AXGroup`, which says "contains
/// things" rather than lying about what it is.
pub fn roleName(role: a11y.Role) []const u8 {
    return switch (role) {
        .window => "AXWindow",
        .button => "AXButton",
        // A toggle is a check box to AppKit; a switch button is drawn, not
        // described, and VoiceOver reads the value either way.
        .toggle => "AXCheckBox",
        .checkbox => "AXCheckBox",
        .label => "AXStaticText",
        .heading => "AXStaticText",
        .text_field => "AXTextField",
        .radio_group => "AXRadioGroup",
        .radio => "AXRadioButton",
        .list => "AXList",
        .list_item => "AXRow",
        .group => "AXGroup",
        .slider => "AXSlider",
        .progress => "AXProgressIndicator",
        .separator => "AXSplitter",
        .image => "AXImage",
    };
}

/// What a reader announces for a node.
///
/// A text field announces its value, a label announces its text, and anything
/// with neither falls back to the description. A node with no name at all
/// announces nothing, which is honest: a reader should not invent a label.
pub fn labelFor(node: *const a11y.Node) []const u8 {
    if (node.name.len > 0) return node.name;
    if (node.value.len > 0) return node.value;
    return node.description;
}

/// The `NSAccessibility` action name for a MyZig action, or null when AppKit
/// has no equivalent.
pub fn actionName(kind: a11y.Kind) ?[]const u8 {
    return switch (kind) {
        .press => "AXPress",
        // Focus is not an action in AppKit: a reader focuses an element by
        // navigating to it. Saying so is better than inventing `AXFocus`.
        .focus => null,
        .increment => "AXIncrement",
        .decrement => "AXDecrement",
    };
}

/// The names of a node's actions, skipping the ones AppKit does not have.
pub fn actionNames(comptime n: usize) fn (node: *const a11y.Node) [n]?[]const u8 {
    return struct {
        fn f(node: *const a11y.Node) [n]?[]const u8 {
            var out: [n]?[]const u8 = @splat(null);
            for (node.actions, 0..) |a, i| {
                if (i >= n) break;
                out[i] = actionName(a.kind);
            }
            return out;
        }
    }.f;
}

/// A node's frame, flipped into its parent's space.
///
/// `parent_height` is the height of whatever this node is a child of, in the
/// same units as the rect, and `view_height` is the receiving *view*'s height.
/// For a direct child of the view those are the same number; a nested element
/// passes its parent element's height instead, which is why the argument is
/// separate rather than derived from the node.
pub fn frameInParentSpace(bounds: @import("../../ui/geometry.zig").Rect, parent_height: f64) objc.CGRect {
    // MyZig's `Rect` is integer DIPs; AppKit takes points as doubles.
    const x: f64 = @floatFromInt(bounds.x);
    const y: f64 = @floatFromInt(bounds.y);
    const w: f64 = @floatFromInt(bounds.width);
    const h: f64 = @floatFromInt(bounds.height);
    return .{
        .x = x,
        .y = parent_height - (y + h),
        .width = w,
        .height = h,
    };
}

/// Whether a node should appear in the tree a reader walks.
///
/// A hidden node has nothing to announce and must not be reachable, so it is
/// skipped along with everything below it.
pub fn isVisible(node: *const a11y.Node) bool {
    return !node.states.hidden;
}

// ------------------------------------------------------------- object graph

/// Elements by node id for the window being published, kept so a press can find
/// the node a reader activated.
pub const Published = struct {
    /// The elements, indexed by node id. Null where a node was skipped.
    elements: []objc.ObjCId = &.{},
    /// The nodes they were built from.
    nodes: []const a11y.Node = &.{},
    window_id: u32 = 0,
    /// The view they hang under, retained for the lifetime of the publish.
    container: objc.ObjCId = null,
    /// What the tree said when it was built. A frame that describes the same
    /// thing skips the rebuild, so VoiceOver is not told to re-read the window
    /// because a spinning indicator repainted a progress bar.
    fingerprint: u64 = 0,
};

/// A cheap summary of everything about a node that reaches AppKit.
///
/// Two trees with the same fingerprint build the same elements, so the second
/// one can be skipped. It is a 64-bit hash rather than a deep comparison
/// because this runs every frame; the cost of a collision is one frame of stale
/// accessibility, not a wrong screen.
///
/// `bounds` is included even though it is not obvious: moving a button changes
/// nothing a reader hears, but it *does* change where VoiceOver draws its
/// highlight and where a hit test lands.
pub fn fingerprint(snapshot: a11y.Snapshot) u64 {
    var h = std.hash.Wyhash.init(0x6d797a67); // "myzg"
    h.update(std.mem.asBytes(&snapshot.nodes.len));
    for (snapshot.nodes) |*n| {
        h.update(std.mem.asBytes(&n.role));
        h.update(std.mem.asBytes(&n.bounds));
        h.update(std.mem.asBytes(&n.states));
        h.update(n.name);
        h.update(n.description);
        h.update(n.value);
        // A length marker after each string, so "ab"+"c" and "a"+"bc" do not
        // hash alike.
        var len = n.name.len;
        h.update(std.mem.asBytes(&len));
        len = n.description.len;
        h.update(std.mem.asBytes(&len));
        len = n.value.len;
        h.update(std.mem.asBytes(&len));
        for (n.actions) |a| {
            h.update(std.mem.asBytes(&a.kind));
            h.update(a.name);
        }
        // The parent decides where the element hangs, so a re-parenting is a
        // different tree even when nothing else moved.
        h.update(std.mem.asBytes(&n.parent));
    }
    return h.final();
}

var published: std.AutoHashMapUnmanaged(u32, Published) = .empty;
var gpa: std.mem.Allocator = undefined;

/// Which window and node each element stands for, so a press that arrives with
/// nothing but the element can be traced back. Populated at publish time and
/// cleared with the same tree, because a pointer that outlived its element
/// would be read after it was freed.
/// What an element stands for: which window's tree it belongs to, and which
/// node in it.
const BackRef = struct { window_id: u32, node_id: u32 };

var back_refs: std.AutoHashMapUnmanaged(usize, BackRef) = .empty;

/// The element class, built once. Held so a press can be answered by a subclass
/// method rather than by polling, which is what AppKit calls.
var element_cls_global: ?objc.Class = null;

/// Drops every element the back-ref map still holds for `window_id`.
fn forgetWindow(window_id: u32) void {
    // `swapRemove` during iteration would skip the element swapped into the
    // hole, so the removals are collected first. A fixed buffer would silently
    // leave stale entries behind in a large tree, which is worse than the cost
    // of the allocation: those entries keep a freed pointer reachable.
    var doomed: std.ArrayListUnmanaged(usize) = .empty;
    defer doomed.deinit(gpa);
    var it = back_refs.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.window_id != window_id) continue;
        doomed.append(gpa, entry.key_ptr.*) catch return;
    }
    for (doomed.items) |key| _ = back_refs.remove(key);
}

/// The node an element stands for, or null when it is not ours.
fn backRefOf(element: objc.ObjCId) ?BackRef {
    const key: usize = @intFromPtr(element);
    return back_refs.get(key);
}

/// `-accessibilityPerformPress`, which AppKit sends when a reader activates the
/// element. Answering BOOL: true means the press was handled.
///
/// This is the whole reason the element is a subclass: a stock
/// `NSAccessibilityElement` has no press, so VoiceOver reads the label and then
/// does nothing when the user asks to activate it.
fn performPress(self: objc.ObjCId, _: ?objc.Sel) callconv(.c) bool {
    const ref = backRefOf(self) orelse return false;
    return press(ref.window_id, ref.node_id);
}

/// Builds `MyZigA11yElement` the first time it is needed. Returns false when the
/// runtime refuses, which the caller reads as "elements stay plain": a reader
/// can then still read the tree, it just cannot press it.
fn registerElementClass() ?objc.Class {
    if (comptime builtin.os.tag != .macos) return null;
    if (element_cls_global) |c| return c;

    const base = objc.class("NSAccessibilityElement") orelse return null;
    const cls = objc.objc_allocateClassPair(base, "MyZigA11yElement", 0) orelse return null;
    // -accessibilityPerformPress answers BOOL, whose encoding is `c`.
    _ = objc.class_addMethod(cls, objc.sel("accessibilityPerformPress"), @ptrCast(&performPress), "c@:");
    objc.objc_registerClassPair(cls);
    element_cls_global = cls;
    return cls;
}

pub fn init(allocator: std.mem.Allocator) void {
    gpa = allocator;
}

pub fn deinit() void {
    var it = published.valueIterator();
    while (it.next()) |p| release(p.*);
    published.deinit(gpa);
    published = .empty;
    back_refs.deinit(gpa);
    back_refs = .empty;
}

fn release(p: Published) void {
    for (p.elements) |e| {
        if (e) |el| objc.sendVoid(el, "release");
    }
    if (p.elements.len > 0) gpa.free(p.elements);
}

/// An `NSString` from a Zig slice. The caller releases it.
fn nsString(text: []const u8) objc.ObjCId {
    const cls = objc.class("NSString") orelse return null;
    const buf = std.heap.c_allocator.alloc(u8, text.len + 1) catch return null;
    defer std.heap.c_allocator.free(buf);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return objc.sendIdCStr(cls, "stringWithUTF8String:", @ptrCast(buf.ptr));
}

/// The action a reader's press should run for `node`, if it has one.
pub fn pressActionFor(node: *const a11y.Node) ?a11y.Action {
    for (node.actions) |a| {
        if (a.kind == .press) return a;
    }
    return null;
}

/// The centre of a node, which is where a press from a reader lands.
pub fn pressPoint(node: *const a11y.Node) struct { x: i32, y: i32 } {
    const b = node.bounds;
    return .{
        .x = b.x + @divTrunc(b.width, 2),
        .y = b.y + @divTrunc(b.height, 2),
    };
}

/// Replaces the tree a reader sees for `window_id`.
///
/// The elements are rebuilt whenever the tree *changes*, which is simplest to
/// get right: an `NSAccessibilityElement` holds a role and a label, and
/// describing a moved tree is easier than patching one. What must not happen is
/// a rebuild for a frame that describes exactly what the last one did — a
/// window repainting at 60 Hz would otherwise ask VoiceOver to re-read itself
/// 60 times a second, which makes the reader unusable rather than fast.
pub fn publish(window_id: u32, container: objc.ObjCId, snapshot: a11y.Snapshot) void {
    if (comptime builtin.os.tag != .macos) return;
    if (snapshot.root == null) return;

    // The same tree, still published for this view: nothing a reader hears has
    // changed, so nothing is rebuilt.
    const fp = fingerprint(snapshot);
    if (published.get(window_id)) |old| {
        if (old.fingerprint == fp and @intFromPtr(old.container) == @intFromPtr(container)) return;
    }

    const element_cls = registerElementClass() orelse objc.class("NSAccessibilityElement") orelse return;
    // Only this window's entries are dropped. Clearing the whole map would take
    // the other windows' elements with it, leaving their presses unanswered for
    // as long as neither window was republished.
    forgetWindow(window_id);

    // One element per node, so a press can be traced back to its node by index.
    const elements = gpa.alloc(objc.ObjCId, snapshot.nodes.len) catch return;
    @memset(elements, null);
    var owned = Published{
        .elements = elements,
        .nodes = snapshot.nodes,
        .window_id = window_id,
        .container = container,
        .fingerprint = fp,
    };
    // A publish replaces the last one; the old elements are released first so
    // a window that is republished every frame does not leak one tree per frame.
    if (published.fetchRemove(window_id)) |kv| release(kv.value);
    published.put(gpa, window_id, owned) catch {
        release(owned);
        return;
    };

    const bounds = objc.sendGetRectNoArg(container, "bounds");
    var id: u32 = 0;
    while (id < snapshot.nodes.len) : (id += 1) {
        const node = &snapshot.nodes[id];
        if (!isVisible(node)) continue;
        // The root is the view itself; the view is already the container, so it
        // gets properties rather than an element of its own.
        if (node.parent == null) continue;

        const el = makeElement(element_cls, node, bounds) orelse continue;
        elements[id] = el;
        owned.elements[id] = el;
        back_refs.put(gpa, @intFromPtr(el), .{ .window_id = window_id, .node_id = id }) catch {};
    }

    // Children of each element, in node order. A node whose parent was skipped
    // (hidden, or the root, which is the view itself) hangs off the container,
    // so nothing becomes unreachable by accident.
    id = 0;
    while (id < snapshot.nodes.len) : (id += 1) {
        const el = elements[id] orelse continue;
        const parent_el = parentElement(elements, snapshot.nodes, &snapshot.nodes[id]);
        objc.sendVoidId(parent_el orelse container, "accessibilityAddChildElement:", el);
    }

    // The view is a container, not an element: it must be marked that way or
    // AppKit reports the whole window as one opaque control.
    objc.sendBool(container, "setAccessibilityElement:", false);
    objc.sendVoidId(container, "setAccessibilityRole:", nsString("AXGroup"));
    objc.sendVoidId(container, "setAccessibilityLabel:", nsString(""));
}

/// The nearest visible ancestor's element, so a hidden node's children stay
/// reachable.
fn parentElement(elements: []objc.ObjCId, nodes: []const a11y.Node, node: *const a11y.Node) objc.ObjCId {
    const pid = nearestPublishedParent(nodes, elements.len, node) orelse return null;
    return elements[pid];
}

/// The nearest ancestor that has an element, skipping hidden ones.
///
/// Written over ids rather than objects so the rule can be tested without
/// AppKit: the objects are only looked up once the id is known.
pub fn nearestPublishedParent(
    nodes: []const a11y.Node,
    element_count: usize,
    node: *const a11y.Node,
) ?u32 {
    var parent = node.parent;
    while (parent) |pid| {
        // `element_count` is how many nodes got an element this frame; a node
        // past the end has none, which is what a hidden subtree leaves behind.
        if (pid < element_count and pid < nodes.len) {
            if (isVisible(&nodes[pid])) return pid;
        }
        parent = nodes[pid].parent;
    }
    return null;
}

/// One `NSAccessibilityElement` for a node.
fn makeElement(element_class: anytype, node: *const a11y.Node, view_bounds: objc.CGRect) ?objc.ObjCId {
    const allocated = objc.sendId1(element_class, "alloc", null) orelse return null;
    const el = objc.sendId1(allocated, "init", null) orelse return null;

    objc.sendVoidId(el, "setAccessibilityRole:", nsString(roleName(node.role)));

    const label = labelFor(node);
    if (label.len > 0) {
        if (nsString(label)) |s| {
            objc.sendVoidId(el, "setAccessibilityLabel:", s);
            objc.sendVoid(s, "release");
        }
    }
    if (node.description.len > 0) {
        if (nsString(node.description)) |s| {
            objc.sendVoidId(el, "setAccessibilityHelp:", s);
            objc.sendVoid(s, "release");
        }
    }
    if (node.value.len > 0) {
        if (nsString(node.value)) |s| {
            objc.sendVoidId(el, "setAccessibilityValue:", s);
            objc.sendVoid(s, "release");
        }
    }

    // The frame is in the container's space, which for a view is its own
    // bounds: bottom-left, Y up.
    objc.sendRect(el, "setAccessibilityFrameInParentSpace:", frameInParentSpace(node.bounds, view_bounds.height));

    objc.sendBool(el, "setAccessibilityEnabled:", node.states.enabled);
    // A press is advertised only when the application gave the node one, so a
    // reader never offers to press something that would do nothing.
    if (pressActionFor(node) != null) {
        objc.sendBool(el, "setAccessibilityPerformPress:", true);
    }
    return el;
}

/// The hook a reader's press goes through. Set by the surface module, which is
/// the only place that knows how to deliver pointer input; `a11y.zig` must not
/// import it back without creating a cycle.
var press_hook: ?*const fn (window_id: u32, x: i32, y: i32) bool = null;

pub fn setPressHook(hook: *const fn (window_id: u32, x: i32, y: i32) bool) void {
    press_hook = hook;
}

/// Runs a press for `window_id` at the centre of node `node_id`, in the tree
/// last published for that window. Returns false when the node has no press
/// action or the window has no surface: a reader pressing something that does
/// nothing must be told no, not silently ignored.
pub fn press(window_id: u32, node_id: u32) bool {
    const p = published.get(window_id) orelse return false;
    if (node_id >= p.nodes.len) return false;
    const node = &p.nodes[node_id];
    if (pressActionFor(node) == null) return false;
    const at = pressPoint(node);
    const hook = press_hook orelse return false;
    return hook(window_id, at.x, at.y);
}

// ------------------------------------------------------------------- tests

test "every role maps to an AppKit role a reader knows" {
    // The set is the AppKit role constants; a wrong one makes VoiceOver read
    // the node as a group rather than refusing it, which is worse than an
    // obvious mistake, so each is asserted to start with AX.
    // Zig 0.17's enum type info names its fields separately from their values.
    const info = @typeInfo(a11y.Role).@"enum";
    inline for (info.field_values, 0..) |value, i| {
        _ = i;
        const name = roleName(@enumFromInt(value));
        try std.testing.expect(name.len > 2);
        try std.testing.expect(std.mem.startsWith(u8, name, "AX"));
    }
}

test "a label falls back from name to value to description" {
    var node = a11y.Node{};
    try std.testing.expectEqualStrings("", labelFor(&node));

    node.description = "explains itself";
    try std.testing.expectEqualStrings("explains itself", labelFor(&node));

    node.value = "42";
    try std.testing.expectEqualStrings("42", labelFor(&node));

    node.name = "Volume";
    try std.testing.expectEqualStrings("Volume", labelFor(&node));
}

test "a frame is flipped into the parent's space exactly once" {
    // A 30-high node 10 from the top of a 100-high parent sits at y = 60.
    const r = frameInParentSpace(.{ .x = 5, .y = 10, .width = 20, .height = 30 }, 100);
    try std.testing.expectEqual(@as(f64, 5), r.x);
    try std.testing.expectEqual(@as(f64, 60), r.y);
    try std.testing.expectEqual(@as(f64, 20), r.width);
    try std.testing.expectEqual(@as(f64, 30), r.height);

    // The top edge of the parent is y = parent_height - height.
    const top = frameInParentSpace(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, 100);
    try std.testing.expectEqual(@as(f64, 90), top.y);
}

test "only press, increment and decrement are AppKit actions" {
    try std.testing.expectEqualStrings("AXPress", actionName(.press).?);
    try std.testing.expectEqualStrings("AXIncrement", actionName(.increment).?);
    try std.testing.expectEqualStrings("AXDecrement", actionName(.decrement).?);
    // Focusing is navigation, not an action, in AppKit.
    try std.testing.expect(actionName(.focus) == null);
}

test "a press lands at the centre of the node" {
    const node = a11y.Node{ .bounds = .{ .x = 10, .y = 20, .width = 40, .height = 20 } };
    const p = pressPoint(&node);
    try std.testing.expectEqual(@as(i32, 30), p.x);
    try std.testing.expectEqual(@as(i32, 30), p.y);
}

test "a hidden parent is skipped so its children stay reachable" {
    //  0 window
    //  1 group (hidden)
    //  2 button inside the hidden group
    var nodes = [_]a11y.Node{
        .{ .id = 0, .role = .window },
        .{ .id = 1, .role = .group, .parent = 0, .states = .{ .hidden = true } },
        .{ .id = 2, .role = .button, .parent = 1 },
    };
    // The hidden group has no element, so the button hangs off the window.
    const parent = nearestPublishedParent(&nodes, nodes.len, &nodes[2]);
    try std.testing.expectEqual(@as(?u32, 0), parent);

    // A visible parent is the answer directly.
    nodes[1].states.hidden = false;
    const direct = nearestPublishedParent(&nodes, nodes.len, &nodes[2]);
    try std.testing.expectEqual(@as(?u32, 1), direct);
}

test "a root has no parent to hang from" {
    var nodes = [_]a11y.Node{.{ .id = 0, .role = .window }};
    try std.testing.expect(nearestPublishedParent(&nodes, nodes.len, &nodes[0]) == null);
}

test "a hidden node is not published" {
    const shown = a11y.Node{};
    try std.testing.expect(isVisible(&shown));

    var hidden = a11y.Node{};
    hidden.states.hidden = true;
    try std.testing.expect(!isVisible(&hidden));
}

/// A tree of `n` nodes made from one builder, so the fixture matches what the
/// application really produces.
fn testTree(allocator: std.mem.Allocator) !a11y.Builder {
    var b = a11y.Builder.init(allocator);
    errdefer b.deinit();
    try b.begin(.{ .x = 0, .y = 0, .width = 200, .height = 100 });
    const group = try b.beginNode(.group, .{ .x = 0, .y = 0, .width = 200, .height = 100 });
    _ = try b.leaf(.button, .{ .x = 10, .y = 10, .width = 60, .height = 20 }, "Play");
    try b.setPressAction(1, "Press");
    b.endNode();
    _ = try b.leaf(.label, .{ .x = 10, .y = 40, .width = 100, .height = 20 }, "Volume");
    _ = group;
    b.endNode();
    return b;
}

test "the same tree has the same fingerprint" {
    var b = try testTree(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqual(fingerprint(b.snapshot()), fingerprint(b.snapshot()));
}

test "a different tree has a different fingerprint" {
    var a = try testTree(std.testing.allocator);
    defer a.deinit();

    var b = try testTree(std.testing.allocator);
    defer b.deinit();

    // The one thing that changed is a label; a reader would hear it.
    _ = b.nodes.items[2].name;
    b.nodes.items[2].name = "Pause";
    try std.testing.expect(fingerprint(a.snapshot()) != fingerprint(b.snapshot()));
}

test "every field a reader hears is part of the fingerprint" {
    var b = try testTree(std.testing.allocator);
    defer b.deinit();
    const base = fingerprint(b.snapshot());

    // A moved node changes where the reader's highlight goes and where a hit
    // test lands, so it must invalidate.
    b.nodes.items[1].bounds.x += 1;
    try std.testing.expect(fingerprint(b.snapshot()) != base);
    b.nodes.items[1].bounds.x -= 1;

    b.nodes.items[1].states.enabled = false;
    try std.testing.expect(fingerprint(b.snapshot()) != base);
    b.nodes.items[1].states.enabled = true;

    b.nodes.items[1].value = "half";
    try std.testing.expect(fingerprint(b.snapshot()) != base);
    b.nodes.items[1].value = "";

    b.nodes.items[1].description = "the play button";
    try std.testing.expect(fingerprint(b.snapshot()) != base);
    b.nodes.items[1].description = "";

    // Back to where it started, and the fingerprint agrees. That is what lets a
    // caller trust it as "unchanged" rather than "changed at least once".
    try std.testing.expectEqual(base, fingerprint(b.snapshot()));
}

test "a press with nothing published is refused, not crashed into" {
    // No window has been published yet, so there is no tree to press in. The
    // reader must be told no: a stale node id must never reach freed memory.
    try std.testing.expect(!press(4242, 0));
    try std.testing.expect(!press(0, 99));
}

test "a node without a press action is not pressable" {
    const node = a11y.Node{};
    try std.testing.expect(pressActionFor(&node) == null);

    const actions = [_]a11y.Action{.{ .name = "Press", .kind = .press }};
    const with_action = a11y.Node{ .actions = &actions };
    try std.testing.expect(pressActionFor(&with_action) != null);

    // A slider's step is not a press, so a reader is not offered one.
    const steps = [_]a11y.Action{.{ .name = "Increment", .kind = .increment }};
    const slider = a11y.Node{ .actions = &steps };
    try std.testing.expect(pressActionFor(&slider) == null);
}

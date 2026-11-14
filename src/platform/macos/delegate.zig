//! The delegates this backend needs: objects AppKit and WebKit call, built at
//! run time out of Zig functions.
//!
//! ## Why a class is built rather than declared
//!
//! A window's close button sends `windowShouldClose:` to its delegate, and a
//! page reports a load failure to
//! `webView:didFailProvisionalNavigation:withError:`. Both need an
//! Objective-C method, and this backend deliberately compiles no Objective-C.
//! `objc_allocateClassPair` lets a class be made at run time from a plain
//! function pointer, so the delegates are Zig: no `.m` file, and no
//! message-sending code the Zig compiler cannot see.
//!
//! ## What a delegate is attached to
//!
//! AppKit holds delegates weakly, so something has to own them. The delegate is
//! retained on the object it serves (`objc_setAssociatedObject`), and the box
//! it carries — the window id and the event sink — is retained on the delegate.
//! Both go when the platform object does, which is why destroying a window
//! releases nothing here.
//!
//! ## Testing
//!
//! Written against Apple's documentation and the runtime ABI, and **never
//! run**: there is no Mac here. Each class below says which signature it
//! matches, because a wrong type encoding is a crash rather than an error.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const backend = @import("../backend.zig");

/// What a delegate reports to. The sink is copied, not pointed at: the app
/// moves after `init` and an address taken here would go stale.
pub const Context = struct {
    sink: backend.EventSink,
    window_id: u32,
};

/// A box the platform retains. It is an ordinary Zig struct rather than an
/// `extern` one: nothing outside Zig reads its fields, the platform only holds
/// the pointer.
const Box = struct {
    ctx: Context,
};

/// Classes are registered once for the process; a second window reuses them.
var registered = false;

fn contextOf(delegate: objc.ObjCId) ?*Box {
    const box = objc.associated(delegate, objc.delegate_key) orelse return null;
    return @ptrCast(@alignCast(box));
}

// ------------------------------------------------------------ window delegate

fn windowShouldClose(_: objc.ObjCId, _: ?objc.Sel, _: objc.ObjCId) callconv(.c) bool {
    // The framework decides. Answering false keeps AppKit from tearing the
    // window down behind the framework's back; `windowWillClose` reports the
    // request, and the application closes it if it agrees.
    return false;
}

fn windowWillClose(self: objc.ObjCId, _: ?objc.Sel, _: objc.ObjCId) callconv(.c) void {
    const b = contextOf(self) orelse return;
    b.ctx.sink.windowCloseRequested(b.ctx.window_id);
}

// --------------------------------------------------------------- web delegate

fn webDidFinish(self: objc.ObjCId, _: ?objc.Sel, _: objc.ObjCId, _: objc.ObjCId) callconv(.c) void {
    const b = contextOf(self) orelse return;
    b.ctx.sink.webLoadFinished(b.ctx.window_id);
}

fn webDidFail(
    self: objc.ObjCId,
    _: ?objc.Sel,
    _: objc.ObjCId,
    _: objc.ObjCId,
    error_obj: objc.ObjCId,
) callconv(.c) void {
    const b = contextOf(self) orelse return;
    // The system's own description, so the application sees "The Internet
    // connection appears to be offline" rather than a code it has no table
    // for.
    var buf: [512]u8 = undefined;
    var span: []const u8 = "navigation failed";
    if (error_obj) |e| {
        if (objc.sendId1(e, "localizedDescription", null)) |d| {
            if (objc.cString(d)) |c| {
                const n = @min(std.mem.len(c), buf.len);
                @memcpy(buf[0..n], c[0..n]);
                span = buf[0..n];
            }
        }
    }
    b.ctx.sink.webLoadFailed(b.ctx.window_id, span);
}

/// Builds the two classes the first time a window is created. Returns false
/// when the runtime refuses, which the caller treats as "no callbacks" rather
/// than as a window that failed to open.
pub fn register() bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (registered) return true;

    const nsobject = objc.class("NSObject") orelse return false;

    const window_class = objc.objc_allocateClassPair(nsobject, "MyZigWindowDelegate", 0) orelse
        return false;
    // -windowShouldClose: answers BOOL; the type encoding of BOOL is `c`.
    _ = objc.class_addMethod(window_class, objc.sel("windowShouldClose:"), @ptrCast(&windowShouldClose), "c@:@");
    _ = objc.class_addMethod(window_class, objc.sel("windowWillClose:"), @ptrCast(&windowWillClose), "v@:@");
    objc.objc_registerClassPair(window_class);

    const web_class = objc.objc_allocateClassPair(nsobject, "MyZigWebDelegate", 0) orelse return false;
    // Both navigation callbacks share one shape: (view, selector, view, error
    // object, error) and answer nothing.
    _ = objc.class_addMethod(web_class, objc.sel("webView:didFinishNavigation:"), @ptrCast(&webDidFinish), "v@:@@@");
    _ = objc.class_addMethod(
        web_class,
        objc.sel("webView:didFailProvisionalNavigation:withError:"),
        @ptrCast(&webDidFail),
        "v@:@@@",
    );
    _ = objc.class_addMethod(
        web_class,
        objc.sel("webView:didFailNavigation:withError:"),
        @ptrCast(&webDidFail),
        "v@:@@@",
    );
    objc.objc_registerClassPair(web_class);

    registered = true;
    return true;
}

// -------------------------------------------------------------- menu target

/// The object every menu item and the tray button report to. One instance is
/// enough: the click carries the item, and the item carries the tag.
var target: objc.ObjCId = null;

/// The sink clicks are reported to, and the command ids by tag.
var click_sink: ?backend.EventSink = null;
var command_ids: [128][]const u8 = undefined;
var command_count: usize = 0;

fn menuItemClicked(_: objc.ObjCId, _: ?objc.Sel, sender: objc.ObjCId) callconv(.c) void {
    const s = click_sink orelse return;
    const item = sender orelse return;
    const tag = objc.sendGetI64(item, "tag");
    if (tag < 0) return;
    const index: usize = @intCast(tag);
    if (index >= command_count) return;
    s.menuCommand(command_ids[index]);
}

fn trayClicked(_: objc.ObjCId, _: ?objc.Sel, _: objc.ObjCId) callconv(.c) void {
    const s = click_sink orelse return;
    // One tray per application, and its menu has one entry, so the id is fixed.
    s.trayClicked(1);
}

/// Records a command id and returns its tag, which is what an `NSMenuItem`
/// carries in place of a string.
pub fn tagFor(id: []const u8) i64 {
    if (command_count == command_ids.len) return -1;
    command_ids[command_count] = id;
    command_count += 1;
    return @intCast(command_count - 1);
}

/// The sink menu clicks are reported to, for code that builds an item after the
/// bar was installed.
pub fn currentSink() ?backend.EventSink {
    return click_sink;
}

/// Forgets every recorded command; called when a new bar replaces the old one,
/// because the old tags then mean nothing.
pub fn resetTags(sink: backend.EventSink) void {
    click_sink = sink;
    command_count = 0;
}

/// The target object for menu items and the tray button. Built once, retained
/// for the life of the process: the menu bar outlives any window.
pub fn menuTarget(sink: backend.EventSink) ?objc.ObjCId {
    if (target) |t| {
        click_sink = sink;
        return t;
    }
    if (comptime builtin.os.tag != .macos) return null;
    const nsobject = objc.class("NSObject") orelse return null;
    const cls = objc.objc_allocateClassPair(nsobject, "MyZigMenuTarget", 0) orelse return null;
    // -menuItemClicked: takes the sender and answers nothing.
    _ = objc.class_addMethod(cls, objc.sel("menuItemClicked:"), @ptrCast(&menuItemClicked), "v@:@");
    _ = objc.class_addMethod(cls, objc.sel("trayClicked:"), @ptrCast(&trayClicked), "v@:@");
    objc.objc_registerClassPair(cls);

    const allocated = objc.sendId1(cls, "alloc", null) orelse return null;
    target = objc.sendId1(allocated, "init", null);
    click_sink = sink;
    return target;
}

/// An `NSString` from a Zig slice, autoreleased by the caller's pool. Shared by
/// the menu and the tray, which both need one.
pub fn nsString(text: []const u8) objc.ObjCId {
    const cls = objc.class("NSString") orelse return null;
    const buf = std.heap.c_allocator.alloc(u8, text.len + 1) catch return null;
    defer std.heap.c_allocator.free(buf);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return objc.sendIdCStr(cls, "stringWithUTF8String:", @ptrCast(buf.ptr));
}

/// Attaches a fresh delegate to `target` and returns it. The caller keeps the
/// pointer only to hand it to `setDelegate:`; ownership is the association, so
/// releasing the platform object releases the delegate and its box.
pub fn attach(target_obj: objc.ObjCId, web: bool, ctx: Context) ?objc.ObjCId {
    if (!register()) return null;
    const cls = objc.class(if (web) "MyZigWebDelegate" else "MyZigWindowDelegate") orelse return null;
    const allocated = objc.sendId1(cls, "alloc", null) orelse return null;
    const delegate = objc.sendId1(allocated, "init", null) orelse return null;

    // `c_allocator` keeps the box independent of any framework allocator, and
    // the association is what frees it in practice: this process never
    // destroys a window without releasing it, and a leak here would be the size
    // of one window's state.
    const box = std.heap.c_allocator.create(Box) catch {
        objc.sendVoid(delegate, "release");
        return null;
    };
    box.* = .{ .ctx = ctx };
    objc.associate(delegate, objc.delegate_key, box);
    objc.associate(target_obj, objc.delegate_key, delegate);
    return delegate;
}

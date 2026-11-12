//! The Objective-C runtime, loaded the way the platform provides it.
//!
//! macOS does not need `dlopen` for these: `libobjc` and the frameworks are
//! linked into every application. The symbols are declared here rather than
//! included from a header, because Zig talks to the runtime directly.
//!
//! ## Why `objc_msgSend` is cast at every call
//!
//! Objective-C sends a message by calling one function with a selector, and the
//! real signature depends on the method — a receiver and selector first, then
//! whatever arguments the method takes. Zig has no variadic call of that shape,
//! so each call site casts the function pointer to the signature it uses. That
//! cast is what the compiler cannot check, so every one is written next to the
//! method it stands for.

const std = @import("std");
const builtin = @import("builtin");

pub const ObjCId = ?*anyopaque;
pub const Sel = *anyopaque;
pub const Class = *anyopaque;

/// The runtime is opened by name rather than linked. `/usr/lib/libobjc.A.dylib`
/// is part of the system, so this never fails on a Mac, and it means a build
/// from a Linux host does not need a macOS SDK to produce a compilable backend.
var runtime: ?std.DynLib = null;

var get_class: *const fn ([*:0]const u8) callconv(.c) ?Class = undefined;
var register_name: *const fn ([*:0]const u8) callconv(.c) ?Sel = undefined;
var send_addr: ?*const anyopaque = null;

fn open() bool {
    if (send_addr != null) return true;
    runtime = std.DynLib.open("/usr/lib/libobjc.A.dylib") catch return false;
    const lib = &runtime.?;
    get_class = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?Class, "objc_getClass") orelse return false;
    register_name = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?Sel, "sel_registerName") orelse return false;
    send_addr = lib.lookup(*const anyopaque, "objc_msgSend") orelse return false;
    return true;
}

pub fn objc_getClass(name: [*:0]const u8) ?Class {
    if (!open()) return null;
    return get_class(name);
}

pub fn sel_registerName(name: [*:0]const u8) ?Sel {
    if (!open()) return null;
    return register_name(name);
}

/// The message sender. Objective-C declares it variadic and with no prototype,
/// which Zig cannot express, so it is taken as an untyped address and cast at
/// each call site to the signature that method actually uses.
pub inline fn msgSend() *const anyopaque {
    if (!open()) return @ptrFromInt(1);
    return send_addr orelse @ptrFromInt(1);
}
pub extern fn objc_allocateClassPair(superclass: ?Class, name: [*:0]const u8, extra: usize) ?Class;
pub extern fn objc_registerClassPair(cls: ?Class) void;
pub extern fn class_addMethod(cls: ?Class, name: ?Sel, imp: *const anyopaque, types: [*:0]const u8) bool;
pub extern fn object_getClass(obj: ObjCId) ?Class;

/// A class looked up by name once and cached, because
/// `objc_getClass` walks the runtime's table every call.
var class_cache: [32]struct { name: [:0]const u8, cls: ?Class } = undefined;
var class_count: usize = 0;

pub fn class(name: [*:0]const u8) ?Class {
    const span = std.mem.span(name);
    for (class_cache[0..class_count]) |entry| {
        if (std.mem.eql(u8, entry.name, span)) return entry.cls;
    }
    const found = objc_getClass(name);
    if (class_count < class_cache.len) {
        // The name is a literal at every call site, so borrowing it is safe.
        class_cache[class_count] = .{ .name = span, .cls = found };
        class_count += 1;
    }
    return found;
}

pub fn sel(name: [*:0]const u8) ?Sel {
    return sel_registerName(name);
}

/// Sends a message that returns nothing.
pub fn sendVoid(obj: ObjCId, selector: [*:0]const u8) void {
    const s = sel(selector) orelse return;
    const f: *const fn (ObjCId, ?Sel) callconv(.c) void = @ptrCast(@alignCast(msgSend()));
    f(obj, s);
}

/// Sends a message that takes one object and returns an object.
pub fn sendId1(obj: ObjCId, selector: [*:0]const u8, a: ObjCId) ObjCId {
    const s = sel(selector) orelse return null;
    const f: *const fn (ObjCId, ?Sel, ObjCId) callconv(.c) ObjCId = @ptrCast(@alignCast(msgSend()));
    return f(obj, s, a);
}

/// Sends a message that takes one integer and returns nothing.
pub fn sendI64(obj: ObjCId, selector: [*:0]const u8, a: i64) void {
    const s = sel(selector) orelse return;
    const f: *const fn (ObjCId, ?Sel, i64) callconv(.c) void = @ptrCast(@alignCast(msgSend()));
    f(obj, s, a);
}

/// Sends a message that takes one integer and returns an object.
pub fn sendIdI64(obj: ObjCId, selector: [*:0]const u8, a: i64) ObjCId {
    const s = sel(selector) orelse return null;
    const f: *const fn (ObjCId, ?Sel, i64) callconv(.c) ObjCId = @ptrCast(@alignCast(msgSend()));
    return f(obj, s, a);
}

/// Sends a message that takes one boolean and returns nothing.
pub fn sendBool(obj: ObjCId, selector: [*:0]const u8, a: bool) void {
    const s = sel(selector) orelse return;
    const f: *const fn (ObjCId, ?Sel, bool) callconv(.c) void = @ptrCast(@alignCast(msgSend()));
    f(obj, s, a);
}

/// A message that returns a boolean.
pub fn sendGetBool(obj: ObjCId, selector: [*:0]const u8) bool {
    const s = sel(selector) orelse return false;
    const f: *const fn (ObjCId, ?Sel) callconv(.c) bool = @ptrCast(@alignCast(msgSend()));
    return f(obj, s);
}

/// A message that returns an integer.
pub fn sendGetI64(obj: ObjCId, selector: [*:0]const u8) i64 {
    const s = sel(selector) orelse return 0;
    const f: *const fn (ObjCId, ?Sel) callconv(.c) i64 = @ptrCast(@alignCast(msgSend()));
    return f(obj, s);
}

/// A message that returns a double.
pub fn sendGetF64(obj: ObjCId, selector: [*:0]const u8) f64 {
    const s = sel(selector) orelse return 0;
    const f: *const fn (ObjCId, ?Sel) callconv(.c) f64 = @ptrCast(@alignCast(msgSend()));
    return f(obj, s);
}

/// `NSMakeRect` by value. A `CGRect` on 64-bit macOS is four doubles, and the
/// ABI passes it in registers like any other 32-byte struct, so it can be
/// declared directly.
pub const CGRect = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const CGPoint = extern struct {
    x: f64,
    y: f64,
};

pub const CGSize = extern struct {
    width: f64,
    height: f64,
};

/// A message taking a rect and returning an object, for `initWithFrame:`.
pub fn sendIdRect(obj: ObjCId, selector: [*:0]const u8, rect: CGRect) ObjCId {
    const s = sel(selector) orelse return null;
    const f: *const fn (ObjCId, ?Sel, CGRect) callconv(.c) ObjCId = @ptrCast(@alignCast(msgSend()));
    return f(obj, s, rect);
}

/// A message taking a rect and returning nothing, for `setFrame:`.
pub fn sendRect(obj: ObjCId, selector: [*:0]const u8, rect: CGRect) void {
    const s = sel(selector) orelse return;
    const f: *const fn (ObjCId, ?Sel, CGRect) callconv(.c) void = @ptrCast(@alignCast(msgSend()));
    f(obj, s, rect);
}

/// A message taking two objects and returning nothing, for `addSubview:`'s
/// two-object cousins such as `setContentView:`.
pub fn sendId2(obj: ObjCId, selector: [*:0]const u8, a: ObjCId, b: ObjCId) ObjCId {
    const s = sel(selector) orelse return null;
    const f: *const fn (ObjCId, ?Sel, ObjCId, ObjCId) callconv(.c) ObjCId = @ptrCast(@alignCast(msgSend()));
    return f(obj, s, a, b);
}

pub fn sendVoidId2(obj: ObjCId, selector: [*:0]const u8, a: ObjCId, b: ObjCId) void {
    const s = sel(selector) orelse return;
    const f: *const fn (ObjCId, ?Sel, ObjCId, ObjCId) callconv(.c) void = @ptrCast(@alignCast(msgSend()));
    f(obj, s, a, b);
}

/// A message taking two doubles and returning nothing, for `setX:y:`.
pub fn sendF64x2(obj: ObjCId, selector: [*:0]const u8, a: f64, b: f64) void {
    const s = sel(selector) orelse return;
    const f: *const fn (ObjCId, ?Sel, f64, f64) callconv(.c) void = @ptrCast(@alignCast(msgSend()));
    f(obj, s, a, b);
}

/// A message taking a C string, for `stringWithUTF8String:`.
pub fn sendIdCStr(obj: ObjCId, selector: [*:0]const u8, s: [*:0]const u8) ObjCId {
    const sel_op = sel(selector) orelse return null;
    const f: *const fn (ObjCId, ?Sel, [*:0]const u8) callconv(.c) ObjCId = @ptrCast(@alignCast(msgSend()));
    return f(obj, sel_op, s);
}

/// A message taking a selector as its argument, for `setTarget:` and
/// `setAction:`'s neighbour `initWithTitle:action:keyEquivalent:`.
pub fn sendIdSel(obj: ObjCId, selector: [*:0]const u8, s: ?Sel) ObjCId {
    const sel_op = sel(selector) orelse return null;
    const f: *const fn (ObjCId, ?Sel, ?Sel) callconv(.c) ObjCId = @ptrCast(@alignCast(msgSend()));
    return f(obj, sel_op, s);
}

/// The UTF-8 bytes of an `NSString`. The buffer belongs to whoever allocated
/// it and must outlive the use; `NSUTF8StringEncoding` is 4.
pub fn cString(obj: ObjCId) ?[*:0]const u8 {
    const s = sel("UTF8String") orelse return null;
    const f: *const fn (ObjCId, ?Sel) callconv(.c) ?[*:0]const u8 = @ptrCast(@alignCast(msgSend()));
    return f(obj, s);
}

test "the runtime is reachable and a class can be looked up" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // `NSObject` is the root of every class and cannot be missing, so a null
    // here means the runtime itself could not be found.
    try std.testing.expect(class("NSObject") != null);
    try std.testing.expect(sel("alloc") != null);
}

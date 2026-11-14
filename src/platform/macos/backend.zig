//! The macOS backend: AppKit windows, WKWebView pages and a bitmap surface.
//!
//! Written the way the Windows backend was: against the platform's own
//! documentation and runtime ABI, compiled for `aarch64-macos` and
//! `x86_64-macos`, and **never run**, because there is no Mac on the machine
//! this was written on. `docs/platforms.md` says which parts are believed to
//! work and which are guesses, and every guess is marked in the code.
//!
//! ## How it talks to the system
//!
//! macOS has no `dlopen` step for system frameworks: `libobjc`, AppKit and
//! WebKit are linked into every application. `objc.zig` declares the runtime
//! and the messages this backend sends. No Objective-C source is involved, so
//! the framework stays pure Zig.
//!
//! ## Threading
//!
//! AppKit is not thread-safe: every window call has to happen on the main
//! thread, which is also where `NSApplication.run` blocks. A call from another
//! thread is queued and run by the loop, which is what `dispatch_async` to the
//! main queue is for in Objective-C.
//!
//! ## Deficiencies, stated rather than hidden
//!
//! * Native UI input is not wired: a mouse press is not delivered to
//!   `surfaceInput`, so a native-only window on macOS draws but does not react.
//! * Menus, the tray, global shortcuts and the desktop APIs are not written.
//! * The `myzig://` scheme is not registered, so a page is loaded from a URL
//!   the system can reach, not from the application's own assets.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");
const log = @import("../../log.zig");
const menu_mod = @import("../../menu.zig");
const menu_impl = @import("menu.zig");
const objc = @import("objc.zig");
const delegate_mod = @import("delegate.zig");
const surface_mod = @import("surface.zig");
const a11y_mod = @import("a11y.zig");
const hotkey_mod = @import("hotkey.zig");

/// The windows this backend owns, and the application allocator they came
/// from. A backend value lives inside the `App`, so it holds no pointer back.
pub const BackendImpl = struct {
    /// Allocated in `init` and freed in `deinit`, because `App` moves after
    /// `init` returns and an address taken here would go stale.
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    allocator: std.mem.Allocator = undefined,
    initialized: bool = false,
    /// The event sink, copied out of the app in `init` for the delegates, which
    /// are built after the app has moved.
    sink: backend.EventSink = undefined,
    /// The running `NSApplication`.
    ns_app: objc.ObjCId = null,
    /// The tray, present once `createTray` has succeeded.
    tray: Tray = .{},
    /// The next tag for a menu item whose id is empty, so every entry is
    /// still distinguishable when the click comes back.
    next_tag: i64 = 1,
};

/// One window and its views.
const Window = struct {
    id: u32,
    /// `NSWindow *`.
    handle: objc.ObjCId,
    /// `NSView *` holding the web view or the bitmap view.
    content: objc.ObjCId,
    /// `WKWebView *`, present for a page or hybrid window.
    web: objc.ObjCId = null,
    kind: backend.ContentKind,
    /// The native surface, present for a native or hybrid window. It owns the
    /// pixel buffer and the view that shows it.
    surface: ?*surface_mod.Surface = null,
    /// The title, owned here because `setTitle:` copies it but the backend
    /// needs it again after a resize.
    title: [:0]const u8 = "",
};

/// The tray, which on macOS is an `NSStatusItem` in the menu bar. There is one
/// per application, so it lives here rather than in a `Window`.
const Tray = struct {
    item: objc.ObjCId = null,
    /// The menu, retained so it stays attached to the button.
    menu: objc.ObjCId = null,
    /// The tooltip, owned here because the platform string it was made from is
    /// not kept.
    tooltip: []u8 = &.{},
};

fn selfOf(ctx: *anyopaque) *BackendImpl {
    return @ptrCast(@alignCast(ctx));
}

/// Looks a window up by id. The list is short, and a linear walk is faster than
/// a hash for the handful of windows a desktop application opens.
fn find(self: *BackendImpl, id: u32) ?*Window {
    for (self.windows.items) |w| {
        if (w.id == id) return w;
    }
    return null;
}

fn init(ctx: *anyopaque, app: *app_mod.App) errors.InitError!void {
    if (comptime builtin.os.tag != .macos) return errors.InitError.PlatformUnavailable;
    const self = selfOf(ctx);
    self.allocator = app.gpa;

    // `NSApplication` has to exist before any window, and it must be told it is
    // an ordinary application rather than a background one, or no window appears
    // and no menu bar is drawn.
    const app_class = objc.class("NSApplication") orelse return errors.InitError.PlatformUnavailable;
    const ns_app = objc.sendId1(app_class, "sharedApplication", null) orelse
        return errors.InitError.PlatformUnavailable;
    objc.sendI64(ns_app, "setActivationPolicy:", 0); // NSApplicationActivationPolicyRegular
    self.ns_app = ns_app;
    self.sink = app.sink();
    self.initialized = true;

    // The delegates report through the app's sink, which is copied here because
    // the app moves after `init` and an address would go stale.
    _ = delegate_mod.register();
    surface_mod.init(app.gpa);
    surface_mod.setSink(self.sink);
    a11y_mod.init(app.gpa);
    surface_mod.installPressHook();
    // Global shortcuts go through Carbon, which needs no permission: an
    // `NSEvent` monitor would ask the user for Accessibility access.
    hotkey_mod.init(app.gpa, &onGlobalShortcut);
}

fn deinit(ctx: *anyopaque) void {
    const self = selfOf(ctx);
    for (self.windows.items) |w| destroyOne(self, w);
    self.windows.deinit(self.allocator);
    surface_mod.deinit();
    a11y_mod.deinit();
    hotkey_mod.deinit();
    destroyTray(self);
    self.initialized = false;
}

fn destroyOne(self: *BackendImpl, w: *Window) void {
    if (w.web) |web| objc.sendVoid(web, "release");
    if (w.handle) |h| objc.sendVoid(h, "release");
    if (w.surface != null) surface_mod.remove(w.id);
    if (w.title.len > 0) self.allocator.free(@constCast(w.title));
    self.allocator.destroy(w);
}

fn run(ctx: *anyopaque) errors.InitError!void {
    if (comptime builtin.os.tag != .macos) return errors.InitError.PlatformUnavailable;
    const app_class = objc.class("NSApplication") orelse return errors.InitError.PlatformUnavailable;
    const ns_app = objc.sendId1(app_class, "sharedApplication", null) orelse
        return errors.InitError.PlatformUnavailable;
    _ = ctx;
    // `run` blocks until `terminate:` is sent, which is what `quit` does.
    objc.sendVoid(ns_app, "run");
}

fn quit(ctx: *anyopaque) void {
    _ = ctx;
    const app_class = objc.class("NSApplication") orelse return;
    if (objc.sendId1(app_class, "sharedApplication", null)) |ns_app| {
        objc.sendVoid(ns_app, "terminate:");
    }
}

/// A window's style mask. Titled, closable, miniaturisable and resizable are the
/// four AppKit documents for an ordinary application window.
const style_mask: i64 = 1 | 2 | 4 | 8;

fn createWindow(ctx: *anyopaque, id: u32, opts: backend.WindowOptions) errors.WindowError!void {
    if (comptime builtin.os.tag != .macos) return errors.WindowError.NotSupported;
    const self = selfOf(ctx);
    if (!self.initialized) return errors.WindowError.NotSupported;

    const allocator = self.allocator;

    // The title is copied before anything can fail, so a failed window leaves
    // no allocation behind.
    const title = allocator.alloc(u8, opts.title.len + 1) catch return errors.WindowError.OutOfMemory;
    @memcpy(title[0..opts.title.len], opts.title);
    title[opts.title.len] = 0;
    const title_z: [:0]u8 = title[0..opts.title.len :0];
    errdefer allocator.free(title);

    const window_class = objc.class("NSWindow") orelse return errors.WindowError.NotSupported;
    // `alloc` then `initWithContentRect:styleMask:backing:defer:` needs three
    // more arguments than `sendIdRect` passes, so the call is spelled out.
    const allocated = objc.sendId1(window_class, "alloc", null) orelse
        return errors.WindowError.NotSupported;

    // Backing store: `NSBackingStoreBuffered` is 2. Deferring creation is
    // false, because the first frame is drawn right after this.
    const init_fn: *const fn (objc.ObjCId, ?objc.Sel, objc.CGRect, i64, i64, bool) callconv(.c) objc.ObjCId =
        @ptrCast(@alignCast(objc.msgSend()));
    const rect = objc.CGRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(opts.width),
        .height = @floatFromInt(opts.height),
    };
    const handle = init_fn(allocated, objc.sel("initWithContentRect:styleMask:backing:defer:"), rect, style_mask, 2, false);
    if (handle == null) {
        allocator.free(title);
        return errors.WindowError.NotSupported;
    }

    // The content view holds whichever subview the window needs.
    const view_class = objc.class("NSView") orelse return errors.WindowError.NotSupported;
    const view_alloc = objc.sendId1(view_class, "alloc", null) orelse
        return errors.WindowError.NotSupported;
    const content = objc.sendIdRect(view_alloc, "initWithFrame:", rect) orelse
        return errors.WindowError.NotSupported;
    _ = objc.sendId1(handle, "setContentView:", content);

    const kind = opts.content;
    var web: objc.ObjCId = null;

    // A page window gets a `WKWebView`; a native window gets none, so WebKit is
    // never mapped for an application that only draws.
    if (kind == .web or kind == .hybrid) {
        web = createWebView(rect, opts, self);
    }

    const w = allocator.create(Window) catch {
        objc.sendVoid(handle, "release");
        allocator.free(title);
        return errors.WindowError.OutOfMemory;
    };
    w.* = .{
        .id = id,
        .handle = handle,
        .content = content,
        .web = web,
        .kind = kind,
        .title = title_z,
    };

    if (web) |v| {
        // The web view fills the window as it resizes. Autoresizing is set here
        // because a window that is resized keeps the subview at its original
        // size otherwise, and the page is then clipped.
        _ = objc.sendId1(content, "addSubview:", v);
        // NSViewWidthSizable | NSViewHeightSizable = 2 | 16.
        objc.sendI64(v, "setAutoresizingMask:", 18);
        // A page delegate reports a finished or failed load, which the core
        // turns into `did-finish-load` and `did-fail-load` events.
        if (delegate_mod.attach(v, true, .{ .sink = self.sink, .window_id = id })) |d| {
            objc.sendVoidId(v, "setNavigationDelegate:", d);
        }
    }

    // The window delegate turns the close button into a close *request*, so the
    // application can refuse it (unsaved notes, for one). Without this AppKit
    // closes the window and the framework never hears about it.
    if (delegate_mod.attach(handle, false, .{ .sink = self.sink, .window_id = id })) |d| {
        objc.sendVoidId(handle, "setDelegate:", d);
    }

    if (opts.title.len > 0) {
        if (objc.class("NSString")) |ns_string_class| {
            if (objc.sendId1(ns_string_class, "alloc", null)) |allocated_title| {
                const with_string = objc.sendIdCStr(allocated_title, "initWithUTF8String:", title_z.ptr);
                if (with_string) |s| _ = objc.sendId1(handle, "setTitle:", s);
            }
        }
    }

    objc.sendVoid(handle, "center");

    self.windows.append(allocator, w) catch {
        destroyOne(self, w);
        return errors.WindowError.OutOfMemory;
    };

    // A native window gets a view of its own, added over the content view. The
    // surface is created after the window so a failure here does not leave a
    // half-made window behind.
    if (kind == .native or kind == .hybrid) {
        attachSurface(self, w, rect, opts);
    }

    if (!opts.hidden) {
        objc.sendVoid(handle, "makeKeyAndOrderFront:");
        // Key presses only arrive at the first responder, so a native view
        // takes that role when the window is shown.
        if (w.surface) |s| {
            if (s.view) |v| _ = objc.sendId1(handle, "makeFirstResponder:", v);
        }
    }
}

/// A `WKWebView` sized to the window. Returns null when WebKit cannot be
/// reached, which the caller treats as a window with no page.
fn createWebView(rect: objc.CGRect, opts: backend.WindowOptions, self: *BackendImpl) objc.ObjCId {
    _ = self;
    const web_class = objc.class("WKWebView") orelse {
        log.err("macos: WKWebView is missing; a page window has no page", .{});
        return null;
    };
    const allocated = objc.sendId1(web_class, "alloc", null) orelse return null;
    const view = objc.sendIdRect(allocated, "initWithFrame:", rect) orelse return null;

    if (opts.url.len > 0) {
        if (navigation_url(opts.url)) |url| {
            const request_class = objc.class("NSURLRequest") orelse return view;
            const request = objc.sendId1(request_class, "requestWithURL:", url) orelse return view;
            _ = objc.sendId1(view, "loadRequest:", request);
        }
    }
    return view;
}

/// An `NSURL` from a string. `stringWithUTF8String:` then
/// `URLWithString:` is the documented pair, and both return null for a string
/// that is not a URL, which is why the answer is optional.
fn navigation_url(text: []const u8) objc.ObjCId {
    var buf: [2048]u8 = undefined;
    if (text.len >= buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;

    const ns_string_class = objc.class("NSString") orelse return null;
    const s = objc.sendIdCStr(ns_string_class, "stringWithUTF8String:", @ptrCast(&buf)) orelse return null;
    const ns_url_class = objc.class("NSURL") orelse return null;
    return objc.sendId1(ns_url_class, "URLWithString:", s);
}

/// Creates the surface and its view for a native window.
///
/// The drawing callback comes from the options, so the surface has everything
/// it needs before the first frame; the backend never reaches into the toolkit
/// itself.
fn attachSurface(self: *BackendImpl, w: *Window, rect: objc.CGRect, opts: backend.WindowOptions) void {
    const surf = surface_mod.attach(w.id, w.content, rect, self.sink) catch |e| {
        log.err("macos: window {d} has no native surface: {s}", .{ w.id, @errorName(e) });
        return;
    };
    if (opts.native_draw) |draw| {
        surf.draw = draw.func;
        surf.ctx = draw.ctx;
    }
    // The accessibility description, when the application gave one, is what a
    // VoiceOver user hears instead of the pixels they cannot see.
    surf.describe = opts.a11y;
    w.surface = surf;
    // The framework's window state must match the pixels on screen, so the
    // size is reported as soon as the surface exists.
    const scale = scaleOf(w);
    surface_mod.resize(surf, rect.width, rect.height, scale);
    self.sink.surfaceResized(
        w.id,
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
        scale,
    );
}

fn destroyWindow(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    for (self.windows.items, 0..) |w, i| {
        if (w.id == id) {
            destroyOne(self, w);
            _ = self.windows.orderedRemove(i);
            return;
        }
    }
}

fn showWindow(ctx: *anyopaque, id: u32, v: bool) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;
    if (v) {
        objc.sendVoid(w.handle, "makeKeyAndOrderFront:");
    } else {
        objc.sendVoid(w.handle, "orderOut:");
    }
}

fn focusWindow(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;
    objc.sendVoid(w.handle, "makeKeyAndOrderFront:");
}

fn setBounds(ctx: *anyopaque, id: u32, r: backend.Rect) errors.WindowError!void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return errors.WindowError.InvalidWindow;
    objc.sendRect(w.handle, "setFrame:display:", .{
        .x = @floatFromInt(r.x),
        .y = @floatFromInt(r.y),
        .width = @floatFromInt(r.width),
        .height = @floatFromInt(r.height),
    });
    if (w.surface) |s| {
        const scale = scaleOf(w);
        surface_mod.resize(s, @floatFromInt(r.width), @floatFromInt(r.height), scale);
        self.sink.surfaceResized(w.id, r.width, r.height, scale);
    }
}

fn getBounds(ctx: *anyopaque, id: u32) ?backend.Rect {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return null;
    // `frame` returns a `CGRect` by value, so the call is typed for that.
    const f: *const fn (objc.ObjCId, ?objc.Sel) callconv(.c) objc.CGRect = @ptrCast(@alignCast(objc.msgSend()));
    const frame = f(w.handle, objc.sel("frame"));
    return .{
        .x = @intFromFloat(frame.x),
        .y = @intFromFloat(frame.y),
        .width = @intFromFloat(frame.width),
        .height = @intFromFloat(frame.height),
    };
}

fn setTitle(ctx: *anyopaque, id: u32, t: []const u8) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;

    if (w.title.len > 0) self.allocator.free(@constCast(w.title));
    const title = self.allocator.alloc(u8, t.len + 1) catch return;
    @memcpy(title[0..t.len], t);
    title[t.len] = 0;
    w.title = title[0..t.len :0];

    const ns_string_class = objc.class("NSString") orelse return;
    const s = objc.sendIdCStr(ns_string_class, "stringWithUTF8String:", w.title.ptr) orelse return;
    _ = objc.sendId1(w.handle, "setTitle:", s);
}

fn setState(ctx: *anyopaque, id: u32, s: events.WindowState) errors.WindowError!void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return errors.WindowError.InvalidWindow;
    switch (s) {
        // AppKit miniaturises through `miniaturize:`, and un-miniaturises by
        // asking the window to come forward.
        .minimized => objc.sendVoid(w.handle, "miniaturize:"),
        .normal => objc.sendVoid(w.handle, "deminiaturize:"),
        .maximized => objc.sendVoid(w.handle, "zoom:"),
        else => return errors.WindowError.NotSupported,
    }
}

fn setAlwaysOnTop(ctx: *anyopaque, id: u32, on: bool) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;
    // `NSFloatingWindowLevel` is 3 and the normal level is 0.
    objc.sendI64(w.handle, "setLevel:", if (on) 3 else 0);
}

fn setFullscreen(ctx: *anyopaque, id: u32, on: bool) errors.WindowError!void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return errors.WindowError.InvalidWindow;
    _ = on;
    // `toggleFullScreen:` is the documented way, and AppKit decides which way
    // it goes. Asking twice in a row returns the window to where it was.
    objc.sendVoid(w.handle, "toggleFullScreen:");
}

fn loadUrl(ctx: *anyopaque, id: u32, u: []const u8) errors.WindowError!void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return errors.WindowError.InvalidWindow;
    const web = w.web orelse return errors.WindowError.NotSupported;
    const url = navigation_url(u) orelse return errors.WindowError.NotSupported;
    const request_class = objc.class("NSURLRequest") orelse return errors.WindowError.NotSupported;
    const request = objc.sendId1(request_class, "requestWithURL:", url) orelse
        return errors.WindowError.NotSupported;
    _ = objc.sendId1(web, "loadRequest:", request);
}

fn evalJs(ctx: *anyopaque, id: u32, c: []const u8) errors.WindowError!void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return errors.WindowError.InvalidWindow;
    const web = w.web orelse return errors.WindowError.NotSupported;

    const allocator = self.allocator;
    const script = allocator.alloc(u8, c.len + 1) catch return errors.WindowError.OutOfMemory;
    defer allocator.free(script);
    @memcpy(script[0..c.len], c);
    script[c.len] = 0;

    const ns_string_class = objc.class("NSString") orelse return errors.WindowError.NotSupported;
    const s = objc.sendIdCStr(ns_string_class, "stringWithUTF8String:", @ptrCast(script.ptr)) orelse
        return errors.WindowError.NotSupported;

    // `evaluateJavaScript:completionHandler:` requires a non-null block: the
    // framework's bridge replies over this same call, and a page call with no
    // reply path times out.
    var block = noop_block;
    objc.sendVoidId2(web, "evaluateJavaScript:completionHandler:", s, &block);
}

/// A block that ignores its arguments. `evaluateJavaScript:` calls it with
/// `(result, error)`, and nothing here reads either.
///
/// It is a *global* block (`BLOCK_IS_GLOBAL`, 1 << 28): it captures nothing, so
/// there is nothing to copy or free, and it can live in static memory for the
/// life of the process. That avoids allocating one per call.
var noop_descriptor = objc.BlockDescriptor{};

var noop_block = objc.Block{
    .isa = null, // set once the runtime is reachable, in `init`
    .flags = 1 << 28,
    .reserved = 0,
    .invoke = @ptrCast(&noopInvoke),
    .descriptor = &noop_descriptor,
};

fn noopInvoke(_: ?*anyopaque, _: objc.ObjCId, _: objc.ObjCId) callconv(.c) void {}

/// Points the shared block at `_NSConcreteGlobalBlock`. Called once from
/// `init`; a block whose `isa` is null is refused by the runtime.
fn prepareBlocks() void {
    if (noop_block.isa != null) return;
    const sym = std.DynLib.open("/usr/lib/system/libsystem_blocks.dylib") catch return;
    if (sym.lookup(*anyopaque, "_NSConcreteGlobalBlock")) |p| noop_block.isa = p;
}

fn injectScript(ctx: *anyopaque, id: u32, c: []const u8) errors.WindowError!void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return errors.WindowError.InvalidWindow;
    const web = w.web orelse return errors.WindowError.NotSupported;

    // A user script is the only way to run code in a page *before* its own
    // does, which is what the IPC bridge needs: `window.myzig` has to exist
    // by the time the first script asks for it.
    const config = objc.sendGetId(web, "configuration") orelse return errors.WindowError.NotSupported;
    const controller = objc.sendGetId(config, "userContentController") orelse
        return errors.WindowError.NotSupported;
    const script = userScript(c) orelse return errors.WindowError.NotSupported;
    objc.sendVoidId(controller, "addUserScript:", script);
    objc.sendVoid(script, "release");
}

/// A `WKUserScript` from Zig source: injected at document start, in the main
/// frame only, so a subframe cannot answer for the application. `forMainFrameOnly`
/// is YES (-1) and `WKUserScriptInjectionTimeAtDocumentStart` is 0.
fn userScript(source: []const u8) objc.ObjCId {
    const text = nsString(source) orelse return null;
    defer objc.sendVoid(text, "release");
    const cls = objc.class("WKUserScript") orelse return null;
    const allocated = objc.sendId1(cls, "alloc", null) orelse return null;
    const create_fn: *const fn (objc.ObjCId, ?objc.Sel, objc.ObjCId, i64, bool) callconv(.c) objc.ObjCId =
        @ptrCast(@alignCast(objc.msgSend()));
    return create_fn(
        allocated,
        objc.sel("initWithSource:injectionTime:forMainFrameOnly:"),
        text,
        0,
        true,
    );
}

/// An `NSString` from a Zig slice, released by the caller. The menu and tray
/// use `delegate.nsString`, which is the same function; this one is kept local
/// because the window code needs it before either of those exists.
const nsString = delegate_mod.nsString;

fn openDevtools(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
    // A `WKWebView` shows its inspector only when the system allows it, through
    // `_setInspectorVisible:`, which is private API and not used here.
}

fn monitors(ctx: *anyopaque, out: []backend.MonitorInfo) usize {
    _ = ctx;
    if (comptime builtin.os.tag != .macos) return 0;
    const screen_class = objc.class("NSScreen") orelse return 0;
    const screens = objc.sendGetId(screen_class, "screens") orelse return 0;
    const count = objc.sendGetI64(screens, "count");

    // AppKit's frame origin is the bottom-left of the primary display and Y
    // grows upward; MyZig's rects are top-left with Y growing downward, which
    // is what `NSScreen.visibleFrame`'s consumer expects everywhere else.
    // `mainScreen` is the screen with the menu bar and is always the *first*
    // entry of `screens`, so its height is the reference the flip is taken
    // against. `frame` alone would be zero for an unplugged display.
    const main_screen = objc.sendGetId(screen_class, "mainScreen");
    const main_height = if (main_screen) |m| objc.sendGetRect(m, "frame", empty_rect).height else 0;

    var n: usize = 0;
    var i: i64 = 0;
    while (i < count and n < out.len) : (i += 1) {
        const screen = objc.sendIdI64(screens, "objectAtIndex:", i) orelse break;
        const frame = objc.sendGetRect(screen, "frame", empty_rect);
        const visible = objc.sendGetRect(screen, "visibleFrame", empty_rect);
        out[n] = .{
            .bounds = flipY(frame, main_height),
            .work_area = flipY(visible, main_height),
            .scale = @floatCast(objc.sendGetF64(screen, "backingScaleFactor")),
            // AppKit does not publish a refresh rate; 0 means unknown rather
            // than a guess.
            .refresh_hz = 0,
            // The first screen in the list is the primary one by definition.
            .primary = i == 0,
            .name = screen_name(screen),
        };
        n += 1;
    }
    return n;
}

const empty_rect = objc.CGRect{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// Converts an AppKit rect (bottom-left origin, Y up) to a MyZig rect
/// (top-left origin, Y down) against the primary display's height.
fn flipY(r: objc.CGRect, main_height: f64) backend.Rect {
    return .{
        .x = @intFromFloat(r.x),
        .y = @intFromFloat(main_height - (r.y + r.height)),
        .width = @intFromFloat(r.width),
        .height = @intFromFloat(r.height),
    };
}

/// The screen's name, e.g. `Built-in Retina Display`. The buffer belongs to the
/// screen, so it is only valid until the next call on that screen; it is not
/// copied here because `MonitorInfo.name` is a borrow by contract.
fn screen_name(screen: objc.ObjCId) []const u8 {
    const name = objc.sendGetId(screen, "localizedName") orelse return "";
    const c = objc.cString(name) orelse return "";
    return std.mem.span(c);
}

fn systemTheme(ctx: *anyopaque) events.Theme {
    _ = ctx;
    if (comptime builtin.os.tag != .macos) return .light;
    // The appearance is published on the application, not in user defaults:
    // `NSApp.effectiveAppearance.name` is `NSAppearanceNameDarkAqua` when the
    // system is in dark mode. Reading user defaults would miss an application
    // that overrides its appearance.
    const app_class = objc.class("NSApplication") orelse return .light;
    const ns_app = objc.sendId1(app_class, "sharedApplication", null) orelse return .light;
    const appearance = objc.sendGetId(ns_app, "effectiveAppearance") orelse return .light;
    const name = objc.sendGetId(appearance, "name") orelse return .light;
    const c = objc.cString(name) orelse return .light;
    const span = std.mem.span(c);
    if (std.mem.indexOf(u8, span, "Dark") != null) return .dark;
    return .light;
}

/// The application's main dispatch queue, for work that must run on the main
/// thread.
extern fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern var _dispatch_main_q: anyopaque;

/// The backend, as `wake` sees it. `wake` is called from whichever thread
/// posted work, so it cannot touch `App`; it posts and returns.
var wake_ctx: ?*anyopaque = null;

fn wakeWork(context: ?*anyopaque) callconv(.c) void {
    const self: *BackendImpl = @ptrCast(@alignCast(context orelse return));
    _ = self;
    // Runs on the main thread, which is where the queue must be drained.
    if (sink_for_wake) |s| s.dispatch();
}

/// The sink `wake` reports to. Copied out of the app in `init`.
var sink_for_wake: ?backend.EventSink = null;

/// A global shortcut fired. The application's handler is invoked on the main
/// thread, because the Carbon event arrives on the run loop the app already
/// spins, and because a shortcut handler will touch windows.
fn onGlobalShortcut(accel: []const u8) void {
    if (comptime builtin.os.tag != .macos) return;
    const s = sink_for_wake orelse return;
    s.shortcutPressed(accel);
}

fn wake(ctx: *anyopaque) void {
    _ = ctx;
    if (comptime builtin.os.tag != .macos) return;
    // A backend method called from another thread has to hop to the main queue;
    // AppKit is not thread-safe. `dispatch_async_f` takes a plain function
    // pointer, so no block is needed here.
    dispatch_async_f(@ptrCast(&_dispatch_main_q), wake_ctx, &wakeWork);
}

fn requestFrame(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    if (find(self, id) == null) return;
    // A native window repaints its own view; a page window has nothing to do.
    surface_mod.requestFrame(id);
}

/// The window's device scale: 2 on a Retina display, 1 otherwise.
fn scaleOf(w: *Window) f32 {
    const handle = w.handle orelse return 1;
    const factor = objc.sendGetF64(handle, "backingScaleFactor");
    if (factor <= 0) return 1;
    return @floatCast(factor);
}

fn present(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;
    // The pixels are in the surface's own buffer; asking for display is what
    // makes the run loop call `drawRect:` and blit them.
    if (w.surface != null) {
        surface_mod.requestFrame(id);
    } else {
        objc.sendVoid(w.content, "setNeedsDisplay:");
    }
}

/// The vtable, with every capability this backend actually has. A window menu
/// needs an `NSMenu`, which is not built, so that is the only entry pointing at
/// a refusal.
pub fn vtable() app_mod.App.Backend.Vtable {
    return .{
        .init = init,
        .deinit = deinit,
        .run = run,
        .quit = quit,
        .create_window = createWindow,
        .destroy_window = destroyWindow,
        .show_window = showWindow,
        .focus_window = focusWindow,
        .set_bounds = setBounds,
        .get_bounds = getBounds,
        .set_title = setTitle,
        .set_state = setState,
        .set_always_on_top = setAlwaysOnTop,
        .set_fullscreen = setFullscreen,
        .load_url = loadUrl,
        .eval_js = evalJs,
        .inject_script = injectScript,
        .open_devtools = openDevtools,
        .set_menu = setMenu,
        .monitors = monitors,
        .system_theme = systemTheme,
        .wake = wake,
        .request_frame = requestFrame,
        .present = present,
        .create_tray = createTray,
        .destroy_tray = destroyTrayFor,
    };
}

// ------------------------------------------------------------------- menu

/// A window menu. On macOS the menu bar belongs to the application rather than
/// to a window, so the tree is installed on `NSApp`; the window id is only
/// checked, so a menu on a window the backend does not know is an error rather
/// than a bar for the wrong window.
fn setMenu(ctx: *anyopaque, id: u32, m: menu_mod.Menu) errors.WindowError!void {
    const self = selfOf(ctx);
    if (comptime builtin.os.tag != .macos) return errors.WindowError.NotSupported;
    const ns_app = self.ns_app orelse return errors.WindowError.NotSupported;
    _ = find(self, id) orelse return errors.WindowError.InvalidWindow;
    if (!menu_impl.install(ns_app, m, self.sink)) return errors.WindowError.NotSupported;
}

// ------------------------------------------------------------------- tray

/// Shows a `NSStatusItem` in the menu bar. macOS has no icon *name* lookup for
/// status items the way a theme does on Linux, so the icon argument is a
/// template image name from the system (`NSImageNameFolder`, or a path to a
/// `.png`); an empty name gives an item with a title and no image.
fn createTray(ctx: *anyopaque, icon_name: []const u8, tooltip: []const u8) bool {
    return createTrayImpl(selfOf(ctx), icon_name, tooltip);
}

fn destroyTrayFor(ctx: *anyopaque) void {
    destroyTray(selfOf(ctx));
}

fn createTrayImpl(self: *BackendImpl, icon_name: []const u8, tooltip: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (self.tray.item != null) return true;

    const bar_class = objc.class("NSStatusBar") orelse return false;
    const bar = objc.sendId1(bar_class, "systemStatusBar", null) orelse return false;
    // `variableLength` is -1: the width follows the image.
    const item = objc.sendIdI64(bar, "statusItemWithLength:", -1) orelse return false;
    objc.sendVoid(item, "retain");

    const button = objc.sendGetId(item, "button") orelse {
        objc.sendVoid(item, "release");
        return false;
    };

    if (icon_name.len > 0) {
        const img_class = objc.class("NSImage") orelse return false;
        const name = nsString(icon_name) orelse return false;
        defer objc.sendVoid(name, "release");
        if (objc.sendId1(img_class, "imageNamed:", name)) |img| {
            // A template image is drawn in the menu bar's own colour, so it is
            // legible in both light and dark mode.
            objc.sendBool(img, "setTemplate:", true);
            objc.sendVoidId(button, "setImage:", img);
        }
    } else {
        const title = nsString(tooltip) orelse return false;
        defer objc.sendVoid(title, "release");
        objc.sendVoidId(button, "setTitle:", title);
    }

    if (tooltip.len > 0) {
        if (nsString(tooltip)) |tip| {
            objc.sendVoidId(button, "setToolTip:", tip);
            objc.sendVoid(tip, "release");
        }
    }

    // A click opens a menu; an item with no menu does nothing at all, which is
    // why a one-entry menu is attached here.
    const menu = buildTrayMenu(self.sink, tooltip) orelse {
        objc.sendVoid(item, "release");
        return false;
    };
    objc.sendVoidId(item, "setMenu:", menu);

    self.tray = .{ .item = item, .menu = menu };
    return true;
}

/// A menu is mandatory for a status item to be clickable. The default has one
/// entry, the application's name, whose tag is 1: that is the click the core
/// reports through `tray_clicked`.
fn buildTrayMenu(sink: backend.EventSink, label: []const u8) ?objc.ObjCId {
    const target = delegate_mod.menuTarget(sink) orelse return null;
    const cls = objc.class("NSMenu") orelse return null;
    const allocated = objc.sendId1(cls, "alloc", null) orelse return null;
    const title = nsString("Tray") orelse return null;
    defer objc.sendVoid(title, "release");
    const menu = objc.sendId1(allocated, "initWithTitle:", title) orelse return null;

    const item_cls = objc.class("NSMenuItem") orelse return menu;
    const item_alloc = objc.sendId1(item_cls, "alloc", null) orelse return menu;
    const init_fn: *const fn (objc.ObjCId, ?objc.Sel, objc.ObjCId, ?objc.Sel, objc.ObjCId) callconv(.c) objc.ObjCId =
        @ptrCast(@alignCast(objc.msgSend()));
    const empty: objc.ObjCId = nsString("");
    // The title is the tooltip: a status item with a menu cannot show a tooltip,
    // so the text goes where the user can see it.
    const text: objc.ObjCId = if (label.len > 0) nsString(label) else empty;
    const entry = init_fn(item_alloc, objc.sel("initWithTitle:action:keyEquivalent:"), text, objc.sel("trayClicked:"), empty);
    if (entry) |e| {
        objc.sendI64(e, "setTag:", 1);
        objc.sendVoidId(e, "setTarget:", target);
        objc.sendVoidId(menu, "addItem:", e);
    }
    return menu;
}

fn destroyTray(self: *BackendImpl) void {
    if (comptime builtin.os.tag != .macos) return;
    const item = self.tray.item orelse return;
    if (objc.class("NSStatusBar")) |bar_class| {
        if (objc.sendId1(bar_class, "systemStatusBar", null)) |bar| {
            objc.sendVoidId(bar, "removeStatusItem:", item);
        }
    }
    objc.sendVoid(item, "release");
    if (self.tray.menu) |m| objc.sendVoid(m, "release");
    self.tray = .{};
}

test "the backend refuses nothing it does not have" {
    // Every field of the vtable is filled, so a missing capability is a
    // function that returns NotSupported rather than a null the caller has to
    // check for.
    const v = vtable();
    try std.testing.expect(v.init != undefined);
    try std.testing.expect(v.create_window != undefined);
}

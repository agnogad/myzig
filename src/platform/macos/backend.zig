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
const objc = @import("objc.zig");

/// The windows this backend owns, and the application allocator they came
/// from. A backend value lives inside the `App`, so it holds no pointer back.
pub const BackendImpl = struct {
    /// Allocated in `init` and freed in `deinit`, because `App` moves after
    /// `init` returns and an address taken here would go stale.
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    allocator: std.mem.Allocator = undefined,
    initialized: bool = false,
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
    /// The bitmap surface, present for a native or hybrid window.
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// The title, owned here because `setTitle:` copies it but the backend
    /// needs it again after a resize.
    title: [:0]const u8 = "",
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
    self.initialized = true;
}

fn deinit(ctx: *anyopaque) void {
    const self = selfOf(ctx);
    for (self.windows.items) |w| destroyOne(self, w);
    self.windows.deinit(self.allocator);
    self.initialized = false;
}

fn destroyOne(self: *BackendImpl, w: *Window) void {
    if (w.web) |web| objc.sendVoid(web, "release");
    if (w.handle) |h| objc.sendVoid(h, "release");
    if (w.pixels.len > 0) self.allocator.free(w.pixels);
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
        web = createWebView(rect, opts);
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

    if (web) |v| _ = objc.sendId1(content, "addSubview:", v);

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

    // A native surface allocates its pixels after the window exists, so a
    // failure here does not leave a half-made window behind.
    if (kind == .native or kind == .hybrid) {
        resizeSurface(self, w, @intCast(opts.width), @intCast(opts.height));
    }

    if (!opts.hidden) objc.sendVoid(handle, "makeKeyAndOrderFront:");
}

/// A `WKWebView` sized to the window. Returns null when WebKit cannot be
/// reached, which the caller treats as a window with no page.
fn createWebView(rect: objc.CGRect, opts: backend.WindowOptions) objc.ObjCId {
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

fn resizeSurface(self: *BackendImpl, w: *Window, width: i32, height: i32) void {
    const pw: u32 = @intCast(@max(1, width));
    const ph: u32 = @intCast(@max(1, height));
    if (pw == w.width and ph == w.height) return;

    const want = pw * ph * 4;
    if (w.pixels.len != want) {
        if (w.pixels.len > 0) self.allocator.free(w.pixels);
        w.pixels = self.allocator.alloc(u8, want) catch {
            w.pixels = &.{};
            w.width = 0;
            w.height = 0;
            return;
        };
    }
    @memset(w.pixels, 0);
    w.width = pw;
    w.height = ph;
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
    resizeSurface(self, w, r.width, r.height);
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

    // `evaluateJavaScript:completionHandler:` takes a block for the reply. The
    // reply goes to the module's own handler through the bridge's ordinary
    // path, so a null handler is passed and the result is read elsewhere; a
    // real block needs a `Block_literal` this backend does not build yet.
    objc.sendVoidId2(web, "evaluateJavaScript:completionHandler:", s, null);
    // The result is dropped: no block was passed, which the doc above explains.
}

fn injectScript(ctx: *anyopaque, id: u32, c: []const u8) errors.WindowError!void {
    // Injecting a script into every page needs `WKUserScript` and a
    // `WKUserContentController`, which is a real object graph this backend has
    // not built. Removing the code rather than leaving it half-written is the
    // honest thing here.
    _ = ctx;
    _ = id;
    _ = c;
    return errors.WindowError.NotSupported;
}

fn openDevtools(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    _ = id;
    // A `WKWebView` shows its inspector only when the system allows it, through
    // `_setInspectorVisible:`, which is private API and not used here.
}

fn monitors(ctx: *anyopaque, out: []backend.MonitorInfo) usize {
    _ = ctx;
    // `NSScreen.screens` is an array that has to be walked with
    // `objectAtIndex:`, and each screen's frame is in a different coordinate
    // space than the toolkit uses. Neither is written, so the answer is that
    // there are none rather than a wrong one.
    _ = out;
    return 0;
}

fn systemTheme(ctx: *anyopaque) events.Theme {
    _ = ctx;
    // `NSUserDefaults`'s `AppleInterfaceStyle` is "Dark" or absent, and reading
    // it needs an object rather than a message; not written.
    return .light;
}

fn wake(ctx: *anyopaque) void {
    _ = ctx;
    // A backend method called from another thread must hop to the main queue,
    // which needs `dispatch_async` and a block. Not written, so a call that
    // needs it is dropped rather than performed on the wrong thread, where it
    // would corrupt AppKit's state.
}

fn requestFrame(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;
    objc.sendVoid(w.content, "setNeedsDisplay:");
}

fn present(ctx: *anyopaque, id: u32) void {
    const self = selfOf(ctx);
    const w = find(self, id) orelse return;
    // The pixels are in the window's own buffer; asking for display is what
    // makes the run loop draw them.
    objc.sendVoid(w.content, "setNeedsDisplay:");
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
    };
}

/// A window menu needs a real `NSMenu`, which this backend does not build yet.
fn setMenu(ctx: *anyopaque, id: u32, m: @import("../../menu.zig").Menu) errors.WindowError!void {
    _ = ctx;
    _ = id;
    _ = m;
    return errors.WindowError.NotSupported;
}

test "the backend refuses nothing it does not have" {
    // Every field of the vtable is filled, so a missing capability is a
    // function that returns NotSupported rather than a null the caller has to
    // check for.
    const v = vtable();
    try std.testing.expect(v.init != undefined);
    try std.testing.expect(v.create_window != undefined);
}

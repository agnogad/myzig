//! The Windows backend: Win32 windows, a WebView2 page, and a native surface
//! drawn with the software rasteriser.
//!
//! **This backend has not been run.** It compiles for `x86_64-windows-gnu`,
//! which is the most that can be checked on a Linux machine. The parts below
//! are written against the documented Win32 and WebView2 APIs; treat them as
//! unverified until someone builds and runs them on Windows.
//!
//! ## Shape
//!
//! * `user32` owns the window, its menu bar and its message loop. One thread —
//!   the one that called `App.run` — pumps it.
//! * WebView2 is loaded at runtime from `WebView2Loader.dll` and driven through
//!   COM. An application that never opens a page never needs the loader, which
//!   is why the load is lazy.
//! * The native surface is an off-screen DIB the rasteriser writes into and
//!   `BitBlt` copies to the window. No GPU path yet.
//!
//! ## Threading
//!
//! Win32 requires every window call to come from the thread that created the
//! window. `App` posts cross-thread work to the main thread, so a backend call
//! that arrives on another thread is queued through `wake`'s message rather than
//! executed. The queue drain runs at the top of the message loop.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const errors = @import("../../errors.zig");
const events = @import("../../events.zig");
const app_mod = @import("../../app.zig");
const menu_mod = @import("../../menu.zig");
const log = @import("../../log.zig");
const ui = @import("../../ui/ui.zig");
const ffi = @import("ffi.zig");
const webview2 = @import("webview2.zig");

/// The window class MyZig registers. One class serves every window.
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MyZigWindow");

/// A message the app posts itself to wake the loop. `WM_APP` is the first
/// value Windows leaves to the application.
const WM_MYZIG_WAKE: ffi.UINT = ffi.WM_APP + 1;

/// The maximum number of windows, matching the core's registry.
const max_windows = 512;

pub const BackendImpl = struct {
    /// The module handle Win32 needs for `CreateWindowExW`.
    instance: ?ffi.HINSTANCE = null,
    class_registered: bool = false,
    /// How to reach the app from the window procedure. Set in `init`.
    sink: ?backend.EventSink = null,
    /// The allocator the app supplied; window state is allocated from it so the
    /// leak checker sees it.
    app_gpa: ?std.mem.Allocator = null,
    /// The thread that owns every window.
    main_thread: ffi.DWORD = 0,
    /// Set by `quit` so the loop stops after the current message.
    running: bool = false,
    /// Whether the class registration must be undone in `deinit`.
    ole_initialised: bool = false,
};

fn impl(ctx: *anyopaque) *BackendImpl {
    return @ptrCast(@alignCast(ctx));
}

// ---------------------------------------------------------------- lifecycle

fn init(ctx: *anyopaque, app: *app_mod.App) errors.InitError!void {
    const self = impl(ctx);
    self.sink = app.sink();
    self.app_gpa = app.gpa;
    wake_sink = self.sink;
    self.main_thread = ffi.GetCurrentThreadId();

    // Per-monitor DPI awareness: without it Windows scales the whole window
    // bitmap and text is blurry on a high-DPI screen.
    _ = ffi.SetProcessDpiAwarenessContext(ffi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // COM is what WebView2 speaks. A failure is not fatal: an application that
    // only draws natively does not need it.
    self.ole_initialised = ffi.OleInitialize(null) >= 0;

    self.instance = ffi.GetModuleHandleW(null);

    var wc = ffi.WNDCLASSEXW{
        .style = ffi.CS_HREDRAW | ffi.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .hInstance = self.instance,
        .hCursor = ffi.LoadCursorW(null, ffi.IDC_ARROW),
        .lpszClassName = class_name,
        // The background is painted by the surface, so painting it here as
        // well would flash the wrong colour on resize.
        .hbrBackground = null,
    };
    if (ffi.RegisterClassExW(&wc) == 0) {
        log.err("win32: RegisterClassExW failed", .{});
        return errors.InitError.PlatformUnavailable;
    }
    self.class_registered = true;
    log.info("windows backend ready", .{});
}

fn deinit(ctx: *anyopaque) void {
    const self = impl(ctx);
    if (self.class_registered) {
        _ = ffi.UnregisterClassW(class_name, self.instance);
        self.class_registered = false;
    }
    if (self.ole_initialised) {
        ffi.OleUninitialize();
        self.ole_initialised = false;
    }
}

fn run(ctx: *anyopaque) errors.InitError!void {
    const self = impl(ctx);
    self.running = true;

    var msg: ffi.MSG = .{};
    while (self.running) {
        // `GetMessageW` blocks until there is work, which is what keeps the
        // process at zero CPU when idle: there is no polling anywhere.
        const rc = ffi.GetMessageW(&msg, null, 0, 0);
        if (rc == 0) break; // WM_QUIT
        if (rc < 0) break; // an error; the loop cannot continue
        _ = ffi.TranslateMessage(&msg);
        _ = ffi.DispatchMessageW(&msg);
    }
    self.running = false;
}

fn quit(ctx: *anyopaque) void {
    const self = impl(ctx);
    self.running = false;
    ffi.PostQuitMessage(0);
}

fn wake(ctx: *anyopaque) void {
    const self = impl(ctx);
    _ = self;
    // The app has queued work; a message to any of our windows would do, but
    // a thread message reaches the loop even with no window open.
    _ = ffi.PostMessageW(null, WM_MYZIG_WAKE, 0, 0);
}

// ------------------------------------------------------------------ windows

fn createWindow(ctx: *anyopaque, id: u32, opts: backend.WindowOptions) errors.WindowError!void {
    const self = impl(ctx);
    // The backend owns each window's Win32 state; the core hands over an id
    // and expects the backend to keep what it needs from then on.
    const gpa = self.app_gpa orelse return errors.WindowError.OutOfMemory;
    const s = gpa.create(WindowState) catch return errors.WindowError.OutOfMemory;
    s.* = .{ .id = id, .gpa = gpa, .kind = opts.content };
    if (reg.get(id) != null) {
        // A stale slot from a window that was never destroyed is replaced.
        reg.remove(id);
    }
    reg.add(s) catch {
        gpa.destroy(s);
        return errors.WindowError.OutOfMemory;
    };

    var title_buf: [512]u16 = undefined;
    const title = ffi.utf16(&title_buf, opts.title) orelse return errors.WindowError.OutOfMemory;

    // The requested size is the client area; the frame comes on top. Without
    // this the window's content is smaller than the caller asked for by
    // exactly the title bar and borders.
    var rect = ffi.RECT{
        .left = 0,
        .top = 0,
        .right = opts.width,
        .bottom = opts.height,
    };
    var style: ffi.DWORD = if (opts.frameless) ffi.WS_POPUP else ffi.WS_OVERLAPPEDWINDOW;
    if (!opts.resizable) style &= ~@as(ffi.DWORD, ffi.WS_THICKFRAME);
    _ = ffi.AdjustWindowRectEx(&rect, style, ffi.FALSE, 0);

    const x = opts.x orelse ffi.CW_USEDEFAULT;
    const y = opts.y orelse ffi.CW_USEDEFAULT;

    const hwnd = ffi.CreateWindowExW(
        ffi.WS_EX_APPWINDOW,
        class_name,
        title,
        style,
        x,
        y,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        self.instance,
        // The window id travels through `lpParam`, so the window procedure can
        // find its own state during `WM_NCCREATE`, before it has a handle to
        // look anything up by.
        @ptrFromInt(@as(usize, id)),
    ) orelse {
        log.err("win32: CreateWindowExW failed", .{});
        return errors.WindowError.NotSupported;
    };

    s.hwnd = hwnd;
    s.sink = self.sink;
    s.width = opts.width;
    s.height = opts.height;
    // A window is a client area of the size asked for, in device pixels once
    // the monitor's DPI is applied.
    s.scale = @as(f32, @floatFromInt(ffi.GetDpiForWindow(hwnd))) / 96.0;

    if (opts.content == .native or opts.content == .hybrid) {
        attachSurface(id, s) catch |e| {
            log.err("native surface: {s}", .{@errorName(e)});
            _ = ffi.DestroyWindow(hwnd);
            s.hwnd = null;
            return errors.WindowError.NotSupported;
        };
    }

    if (opts.content == .web or opts.content == .hybrid) {
        if (opts.url.len > 0) {
            loadUrl(ctx, id, opts.url) catch |e| {
                // A page that cannot load is not fatal for a hybrid window: the
                // native surface still works.
                log.err("webview2: {s}", .{@errorName(e)});
            };
        }
    }

    if (!opts.hidden) {
        _ = ffi.ShowWindow(hwnd, ffi.SW_SHOWNORMAL);
        _ = ffi.UpdateWindow(hwnd);
    }
}

fn destroyWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    if (s.webview) |wv| wv.destroy();
    freeSurface(s);
    if (s.hwnd) |h| {
        _ = ffi.DestroyWindow(h);
        s.hwnd = null;
    }
    reg.remove(id);
    const gpa = s.gpa;
    gpa.destroy(s);
}

fn showWindow(ctx: *anyopaque, id: u32, visible: bool) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    const h = s.hwnd orelse return;
    _ = ffi.ShowWindow(h, if (visible) ffi.SW_SHOWNORMAL else ffi.SW_HIDE);
}

fn focusWindow(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    const h = s.hwnd orelse return;
    _ = ffi.SetForegroundWindow(h);
}

fn setBounds(ctx: *anyopaque, id: u32, r: backend.Rect) errors.WindowError!void {
    _ = ctx;
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const h = s.hwnd orelse return errors.WindowError.NotSupported;

    var rect = ffi.RECT{ .left = 0, .top = 0, .right = r.width, .bottom = r.height };
    _ = ffi.AdjustWindowRectEx(&rect, ffi.WS_OVERLAPPEDWINDOW, ffi.FALSE, 0);
    if (ffi.SetWindowPos(
        h,
        null,
        r.x,
        r.y,
        rect.right - rect.left,
        rect.bottom - rect.top,
        ffi.SWP_NOZORDER | ffi.SWP_SHOWWINDOW,
    ) == 0) return errors.WindowError.NotSupported;
}

fn getBounds(ctx: *anyopaque, id: u32) ?backend.Rect {
    _ = ctx;
    const s = reg.get(id) orelse return null;
    const h = s.hwnd orelse return null;
    var r: ffi.RECT = .{};
    if (ffi.GetWindowRect(h, &r) == 0) return null;
    return .{
        .x = r.left,
        .y = r.top,
        .width = r.right - r.left,
        .height = r.bottom - r.top,
    };
}

fn setTitle(ctx: *anyopaque, id: u32, t: []const u8) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    const h = s.hwnd orelse return;
    var buf: [512]u16 = undefined;
    const w = ffi.utf16(&buf, t) orelse return;
    _ = ffi.SetWindowTextW(h, w);
}

fn setState(ctx: *anyopaque, id: u32, state: events.WindowState) errors.WindowError!void {
    _ = ctx;
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const h = s.hwnd orelse return errors.WindowError.NotSupported;
    const cmd: c_int = switch (state) {
        .normal => ffi.SW_RESTORE,
        .minimized => ffi.SW_MINIMIZE,
        .maximized => ffi.SW_MAXIMIZE,
        .fullscreen => ffi.SW_SHOWNORMAL,
    };
    _ = ffi.ShowWindow(h, cmd);
}

fn setAlwaysOnTop(ctx: *anyopaque, id: u32, on: bool) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    const h = s.hwnd orelse return;
    _ = ffi.SetWindowPos(
        h,
        if (on) ffi.HWND_TOPMOST else ffi.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        ffi.SWP_NOMOVE | ffi.SWP_NOSIZE | ffi.SWP_NOACTIVATE,
    );
}

fn setFullscreen(ctx: *anyopaque, id: u32, on: bool) errors.WindowError!void {
    _ = ctx;
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const h = s.hwnd orelse return errors.WindowError.NotSupported;

    if (on) {
        // Remember the style and rectangle to restore on the way out.
        s.saved_style = @intCast(ffi.GetWindowLongPtrW(h, ffi.GWL_STYLE));
        _ = ffi.GetWindowRect(h, &s.saved_rect.?);
        _ = ffi.SetWindowLongPtrW(h, ffi.GWL_STYLE, @intCast(ffi.WS_POPUP | ffi.WS_VISIBLE));
        const screen_w = ffi.GetSystemMetrics(ffi.SM_CXSCREEN);
        const screen_h = ffi.GetSystemMetrics(ffi.SM_CYSCREEN);
        _ = ffi.SetWindowPos(h, ffi.HWND_TOP, 0, 0, screen_w, screen_h, ffi.SWP_FRAMECHANGED | ffi.SWP_SHOWWINDOW);
    } else {
        _ = ffi.SetWindowLongPtrW(h, ffi.GWL_STYLE, @intCast(s.saved_style));
        if (s.saved_rect) |r| {
            _ = ffi.SetWindowPos(
                h,
                ffi.HWND_TOP,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                ffi.SWP_FRAMECHANGED | ffi.SWP_SHOWWINDOW,
            );
        }
        s.saved_rect = null;
    }
}

fn setMenu(ctx: *anyopaque, id: u32, m: menu_mod.Menu) errors.WindowError!void {
    menu_id_count = 0;
    _ = ctx;
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const h = s.hwnd orelse return errors.WindowError.NotSupported;

    const bar = buildMenu(m) orelse return errors.WindowError.NotSupported;
    if (s.menu) |old| _ = ffi.DestroyMenu(old);
    s.menu = bar;
    if (ffi.SetMenu(h, bar) == 0) return errors.WindowError.NotSupported;
    _ = ffi.DrawMenuBar(h);
}

/// Builds a Win32 menu from a `Menu`.
///
/// The menu is Win32's own memory, so the strings are encoded into stack
/// buffers that `AppendMenuW` copies.
fn buildMenu(m: menu_mod.Menu) ?ffi.HMENU {
    const bar = ffi.CreatePopupMenu() orelse return null;
    for (m.items) |item| {
        switch (item) {
            .submenu => |sub| {
                const popup = ffi.CreatePopupMenu() orelse continue;
                for (sub.items) |child| appendMenuItem(popup, child);
                var label_buf: [256]u16 = undefined;
                const label = ffi.utf16(&label_buf, sub.label) orelse continue;
                _ = ffi.AppendMenuW(bar, ffi.MF_POPUP, @intFromPtr(popup), label);
            },
            else => appendMenuItem(bar, item),
        }
    }
    return bar;
}

fn appendMenuItem(parent: ffi.HMENU, item: menu_mod.Item) void {
    switch (item) {
        .separator => {
            _ = ffi.AppendMenuW(parent, ffi.MF_SEPARATOR, 0, null);
        },
        .command => |c| {
            var label_buf: [256]u16 = undefined;
            const label = ffi.utf16(&label_buf, c.label) orelse return;
            _ = ffi.AppendMenuW(parent, ffi.MF_STRING, commandId(c.id), label);
        },
        .checkbox => |c| {
            var label_buf: [256]u16 = undefined;
            const label = ffi.utf16(&label_buf, c.label) orelse return;
            var flags: ffi.UINT = ffi.MF_STRING;
            if (c.checked) flags |= ffi.MF_CHECKED;
            _ = ffi.AppendMenuW(parent, flags, commandId(c.id), label);
        },
        .radio => |r| {
            var label_buf: [256]u16 = undefined;
            const label = ffi.utf16(&label_buf, r.label) orelse return;
            var flags: ffi.UINT = ffi.MF_STRING;
            if (r.checked) flags |= ffi.MF_CHECKED;
            _ = ffi.AppendMenuW(parent, flags, commandId(r.id), label);
        },
        .submenu => |sub| {
            const popup = ffi.CreatePopupMenu() orelse return;
            for (sub.items) |child| appendMenuItem(popup, child);
            var label_buf: [256]u16 = undefined;
            const label = ffi.utf16(&label_buf, sub.label) orelse return;
            _ = ffi.AppendMenuW(parent, ffi.MF_POPUP, @intFromPtr(popup), label);
        },
    }
}

/// Turns a Win32 command id back into the application's menu item id.
///
/// Win32 reports a 16-bit number, so the mapping is kept in a fixed table that
/// `appendMenuItem` fills as it builds the menu.
fn menu_id_for(command: u16) ?[]const u8 {
    for (menu_ids) |entry| {
        if (entry.command == command) return entry.id;
    }
    return null;
}

const MenuId = struct { command: u16, id: []const u8 };

/// The ids registered by the most recent menu build. A window builds its menu
/// once, so this is enough; a second window's menu replaces it, which matches
/// Win32's own single-menu-per-window model.
var menu_ids: [256]MenuId = @splat(.{ .command = 0, .id = "" });
var menu_id_count: usize = 0;

/// Win32 reports a chosen item by a 16-bit command id. The application's ids
/// are strings, so they are hashed into that range and the table below maps
/// them back.
fn commandId(id: []const u8) usize {
    const h = std.hash.Wyhash.hash(0x6d656e75, id);
    // 1 is `IDOK`, which a dialog reserves; skipping 0 keeps "no item".
    const command: u16 = @intCast((h % 60000) + 1);
    if (menu_id_count < menu_ids.len) {
        menu_ids[menu_id_count] = .{ .command = command, .id = id };
        menu_id_count += 1;
    }
    return command;
}

// --------------------------------------------------------------------- page

fn loadUrl(ctx: *anyopaque, id: u32, u: []const u8) errors.WindowError!void {
    const self = impl(ctx);
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const h = s.hwnd orelse return errors.WindowError.NotSupported;

    if (s.webview == null) {
        _ = self;
        s.webview = webview2.create(s, h) catch |e| {
            log.err("webview2: cannot create the controller: {s}", .{@errorName(e)});
            return errors.WindowError.NotSupported;
        };
    }
    s.webview.?.navigate(u) catch |e| {
        log.err("webview2: navigate failed: {s}", .{@errorName(e)});
        return errors.WindowError.NotSupported;
    };
}

fn evalJs(ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void {
    _ = ctx;
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const wv = s.webview orelse return errors.WindowError.NotSupported;
    wv.eval(code) catch |e| {
        log.err("webview2: eval failed: {s}", .{@errorName(e)});
        return errors.WindowError.NotSupported;
    };
}

fn injectScript(ctx: *anyopaque, id: u32, code: []const u8) errors.WindowError!void {
    _ = ctx;
    const s = reg.get(id) orelse return errors.WindowError.NotSupported;
    const wv = s.webview orelse return errors.WindowError.NotSupported;
    wv.addScript(code) catch |e| {
        log.err("webview2: inject failed: {s}", .{@errorName(e)});
        return errors.WindowError.NotSupported;
    };
}

fn openDevtools(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    const wv = s.webview orelse return;
    wv.openDevtools();
}

// ---------------------------------------------------------------- native UI

/// Creates the off-screen bitmap the rasteriser draws into.
fn attachSurface(id: u32, s: *WindowState) !void {
    _ = id;
    const w = @max(s.width, 1);
    const h = @max(s.height, 1);

    const screen = ffi.GetDC(null) orelse return error.NotSupported;
    defer _ = ffi.ReleaseDC(null, screen);

    const mem = ffi.CreateCompatibleDC(screen) orelse return error.NotSupported;
    var bits: ?*anyopaque = null;
    var header = ffi.BITMAPINFOHEADER{
        .biWidth = w,
        // A negative height asks for a top-down bitmap, which is the order the
        // rasteriser writes in. A positive one would flip the image.
        .biHeight = -@as(i32, h),
    };
    const bmp = ffi.CreateDIBSection(mem, &header, ffi.DIB_RGB_COLORS, &bits, null, 0) orelse {
        _ = ffi.DeleteDC(mem);
        return error.NotSupported;
    };
    _ = ffi.SelectObject(mem, bmp);

    const px: [*]u8 = @ptrCast(bits orelse {
        _ = ffi.DeleteObject(bmp);
        _ = ffi.DeleteDC(mem);
        return error.NotSupported;
    });

    s.surface = .{
        .dc = mem,
        .bitmap = bmp,
        .pixels = px[0 .. @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4],
        .width = w,
        .height = h,
    };
    s.builder = ui.Builder.init(s.gpa);
}

fn freeSurface(s: *WindowState) void {
    if (s.surface) |surf| {
        _ = ffi.DeleteObject(surf.bitmap);
        _ = ffi.DeleteDC(surf.dc);
        s.surface = null;
    }
}

fn paint(s: *WindowState) void {
    const h = s.hwnd orelse return;
    const surf = &(s.surface orelse return);

    var ps: ffi.PAINTSTRUCT = .{};
    const dc = ffi.BeginPaint(h, &ps) orelse return;
    defer _ = ffi.EndPaint(h, &ps);

    if (s.kind == .native or s.kind == .hybrid) {
        // Redraw from scratch: the buffer is reused between frames, so old
        // content would otherwise show through.
        @memset(surf.pixels, 0);
        s.builder.reset();
        if (s.native_draw) |draw| {
            draw.func(
                draw.ctx,
                @ptrCast(&s.builder),
                .{ .x = 0, .y = 0, .width = surf.width, .height = surf.height },
                s.scale,
            );
            ui.canvas.render(
                ui.Surface.init(surf.pixels, @intCast(surf.width), @intCast(surf.height)),
                s.builder.commands.items,
                1,
            );
        }
        _ = ffi.BitBlt(dc, 0, 0, surf.width, surf.height, surf.dc, 0, 0, ffi.SRCCOPY);
    }
}

fn requestFrame(ctx: *anyopaque, id: u32) void {
    _ = ctx;
    const s = reg.get(id) orelse return;
    const h = s.hwnd orelse return;
    // An invalidation reaches `WM_PAINT` through the queue, so the frame is
    // drawn in the loop rather than inside whatever call asked for it.
    _ = ffi.InvalidateRect(h, null, ffi.FALSE);
}

fn present(ctx: *anyopaque, id: u32) void {
    requestFrame(ctx, id);
}

// ------------------------------------------------------------------ monitors

fn monitors(ctx: *anyopaque, out: []backend.MonitorInfo) usize {
    _ = ctx;
    const Counter = struct {
        var items: []backend.MonitorInfo = &.{};
        var n: usize = 0;

        fn each(hmon: ?*anyopaque, _: ?ffi.HDC, _: *ffi.RECT, _: ffi.LPARAM) callconv(ffi.WINAPI) ffi.BOOL {
            if (n >= items.len) return ffi.FALSE;
            var info = ffi.MONITORINFO{};
            if (ffi.GetMonitorInfoW(hmon, &info) == 0) return ffi.TRUE;
            const r = info.rcMonitor;
            items[n] = .{
                .bounds = .{
                    .x = r.left,
                    .y = r.top,
                    .width = r.right - r.left,
                    .height = r.bottom - r.top,
                },
                .work_area = .{
                    .x = info.rcWork.left,
                    .y = info.rcWork.top,
                    .width = info.rcWork.right - info.rcWork.left,
                    .height = info.rcWork.bottom - info.rcWork.top,
                },
                .primary = (info.dwFlags & ffi.MONITORINFOF_PRIMARY) != 0,
                .scale = 1.0,
            };
            n += 1;
            return ffi.TRUE;
        }
    };
    Counter.items = out;
    Counter.n = 0;
    _ = ffi.EnumDisplayMonitors(null, null, Counter.each, 0);
    return Counter.n;
}

fn systemTheme(ctx: *anyopaque) events.Theme {
    _ = ctx;
    // Windows exposes the app theme through the registry; reading it needs a
    // key handle and a parser. Until that is written, the light theme is
    // reported, which is Windows' own default.
    return .light;
}

// -------------------------------------------------------------- window proc

fn wndProc(hwnd: ffi.HWND, message: ffi.UINT, wparam: ffi.WPARAM, lparam: ffi.LPARAM) callconv(ffi.WINAPI) ffi.LRESULT {
    switch (message) {
        ffi.WM_NCCREATE => {
            // The window has no state attached yet, so the id travels in the
            // creation parameter. It is stored in `GWLP_USERDATA`, which every
            // later message reads back.
            const id: u32 = @intCast(@as(usize, @bitCast(lparam)));
            _ = ffi.SetWindowLongPtrW(hwnd, ffi.GWLP_USERDATA, @intCast(id));
            if (reg.get(id)) |s| s.hwnd = hwnd;
            return ffi.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        ffi.WM_SIZE => {
            const s = stateOf(hwnd) orelse return 0;
            const raw: u32 = @truncate(@as(usize, @bitCast(lparam)));
            const w: i32 = @intCast(raw & 0xffff);
            const h: i32 = @intCast((raw >> 16) & 0xffff);
            resizeSurface(s, w, h);
            return 0;
        },
        ffi.WM_PAINT => {
            if (stateOf(hwnd)) |s| {
                paint(s);
                if (s.surface == null) {
                    // A window with no surface (a pure web window) still has to
                    // validate the paint or Windows keeps sending it.
                    var ps: ffi.PAINTSTRUCT = .{};
                    _ = ffi.BeginPaint(hwnd, &ps);
                    _ = ffi.EndPaint(hwnd, &ps);
                }
            }
            return 0;
        },
        ffi.WM_LBUTTONDOWN => {
            if (stateOf(hwnd)) |s| {
                if (s.input) |input| {
                    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, @bitCast(lparam)) & 0xffff)));
                    const y: f32 = @floatFromInt(@as(i16, @truncate((@as(isize, @bitCast(lparam)) >> 16) & 0xffff)));
                    if (input.call(input.ctx, s.id, x, y)) {
                        _ = ffi.InvalidateRect(hwnd, null, ffi.FALSE);
                    }
                }
            }
            return 0;
        },
        ffi.WM_COMMAND => {
            // A menu item was chosen: the low word is the item's id.
            if (stateOf(hwnd)) |s| {
                // The low word is the command id `appendMenuItem` assigned.
                const item_id: u16 = @truncate(wparam);
                if (menu_id_for(item_id)) |name| {
                    if (s.sink) |sink| sink.menuCommand(name);
                }
            }
            return 0;
        },
        ffi.WM_CLOSE => {
            if (stateOf(hwnd)) |s| {
                if (s.sink) |sink| sink.vtable.window_close_requested(sink.ctx, s.id);
            }
            return 0;
        },
        ffi.WM_DESTROY => {
            if (stateOf(hwnd)) |s| {
                if (s.sink) |sink| sink.vtable.window_closed(sink.ctx, s.id);
            }
            return 0;
        },
        WM_MYZIG_WAKE => {
            // The app posted work from another thread; draining it here keeps
            // every window call on the thread that owns the windows.
            if (wake_sink) |sink| {
                sink.vtable.dispatch(sink.ctx);
            }
            return 0;
        },
        else => return ffi.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

/// The app's sink, needed inside the window procedure where Windows passes no
/// context of our own. There is one application per process.
var wake_sink: ?backend.EventSink = null;

fn stateOf(hwnd: ffi.HWND) ?*WindowState {
    const id = idOf(hwnd) orelse return null;
    return reg.get(id);
}

fn idOf(hwnd: ffi.HWND) ?u32 {
    const raw = ffi.GetWindowLongPtrW(hwnd, ffi.GWLP_USERDATA);
    if (raw == 0) return null;
    return @intCast(raw);
}

fn resizeSurface(s: *WindowState, w: i32, h: i32) void {
    if (s.surface == null) return;
    if (w == s.surface.?.width and h == s.surface.?.height) return;
    freeSurface(s);
    s.width = w;
    s.height = h;
    attachSurface(s.id, s) catch {
        log.err("native surface: cannot resize to {d}x{d}", .{ w, h });
    };
    _ = ffi.InvalidateRect(s.hwnd, null, ffi.FALSE);
}

// --------------------------------------------------------------- the state

/// One window's Windows-side state.
pub const WindowState = struct {
    id: u32 = 0,
    hwnd: ?ffi.HWND = null,
    gpa: std.mem.Allocator,
    /// How to reach the app from the window procedure.
    sink: ?backend.EventSink = null,
    kind: backend.ContentKind = .web,
    width: i32 = 800,
    height: i32 = 600,
    scale: f32 = 1.0,
    webview: ?*webview2.WebView2 = null,
    surface: ?Surface = null,
    builder: ui.Builder = undefined,
    native_draw: ?backend.NativeDraw = null,
    /// Called on a left-button press with the position in device-independent
    /// pixels. Set by the application through `App.setSurfaceInput`.
    input: ?InputHandler = null,
    menu: ?ffi.HMENU = null,
    saved_style: u32 = 0,
    saved_rect: ?ffi.RECT = null,
};

/// The press handler, type-erased the same way the app erases it.
pub const InputHandler = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, id: u32, x: f32, y: f32) bool,
};

pub const Surface = struct {
    dc: ffi.HDC,
    bitmap: ffi.HBITMAP,
    pixels: []u8,
    width: i32,
    height: i32,
};

/// The window registry. Windows are found by the id the core assigned, which
/// is what every entry point receives.
const reg = struct {
    // Zig has no array-repeat operator, so the array is splatted.
    var map: [max_windows]?*WindowState = @splat(null);

    fn get(id: u32) ?*WindowState {
        const s = map[id % max_windows] orelse return null;
        if (s.id != id) return null;
        return s;
    }

    fn add(s: *WindowState) !void {
        const slot = s.id % max_windows;
        if (map[slot] != null) return error.WindowExists;
        map[slot] = s;
    }

    fn remove(id: u32) void {
        const slot = id % max_windows;
        if (map[slot]) |s| {
            if (s.id == id) map[slot] = null;
        }
    }
};

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

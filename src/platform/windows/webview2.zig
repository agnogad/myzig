//! The WebView2 page, driven through COM.
//!
//! WebView2 is loaded from `WebView2Loader.dll` at runtime, so an application
//! that never opens a page does not need it installed and never maps it. The
//! loader is what ships with the Evergreen WebView2 runtime, which is part of
//! Windows 11 and a redistributable on Windows 10.
//!
//! **Not run.** This compiles for `x86_64-windows-gnu`; the COM vtable layouts
//! are written from the documented WebView2 IDL. Treat every call as
//! unverified until someone runs it on Windows.
//!
//! ## How a page is brought up
//!
//! 1. `CreateCoreWebView2EnvironmentWithOptions` builds an environment, which
//!    arrives asynchronously through a handler.
//! 2. The environment's `CreateCoreWebView2Controller` puts a controller in
//!    the window; that arrives through a second handler.
//! 3. The controller's `CoreWebView2` is the browser: it navigates, runs
//!    script and hosts the `postMessage` channel the bridge uses.
//!
//! COM's rule for both steps is the same: the object arrives in `Invoke`, and
//! the caller must not block waiting for it. The page's URL is therefore kept
//! and used once the controller is ready.

const std = @import("std");
const ffi = @import("ffi.zig");
const log = @import("../../log.zig");

pub const Error = error{
    LoaderMissing,
    LoaderIncomplete,
    EnvironmentFailed,
    ControllerFailed,
    NotSupported,
    OutOfMemory,
    NavigationFailed,
    ScriptFailed,
};

/// The loader's only entry point. It is the whole reason for the runtime load.
const CreateEnvironmentFn = *const fn (
    ?[*:0]const u16,
    ?[*:0]const u16,
    ?*anyopaque,
    *const EnvironmentHandler.Vtbl,
) callconv(ffi.WINAPI) ffi.HRESULT;

var loader: ?ffi.HMODULE = null;
var create_environment: ?CreateEnvironmentFn = null;

/// Loads `WebView2Loader.dll` once per process.
fn loadLoader() Error!void {
    if (create_environment != null) return;

    var wide: [260]u16 = undefined;
    const name = ffi.utf16(&wide, "WebView2Loader.dll") orelse return Error.LoaderMissing;
    const h = ffi.LoadLibraryW(name) orelse return Error.LoaderMissing;
    loader = h;

    const proc = ffi.GetProcAddress(h, "CreateCoreWebView2EnvironmentWithOptions") orelse {
        return Error.LoaderIncomplete;
    };
    create_environment = @ptrCast(@alignCast(proc));
}

/// Reads the vtable pointer out of a COM object.
///
/// A COM object's first field is a pointer to its vtable. The object arrives
/// as `*anyopaque`, so the pointer is read as a value rather than through a
/// dereference of an opaque type, which would not compile.
fn vtableOf(obj: *anyopaque) *const CoreWebView2Vtbl {
    const slot: *const *const CoreWebView2Vtbl = @ptrCast(@alignCast(obj));
    return slot.*;
}

fn controllerVtableOf(obj: *anyopaque) *const ControllerVtbl {
    const slot: *const *const ControllerVtbl = @ptrCast(@alignCast(obj));
    return slot.*;
}

fn environmentVtableOf(obj: *anyopaque) *const EnvironmentVtbl {
    const slot: *const *const EnvironmentVtbl = @ptrCast(@alignCast(obj));
    return slot.*;
}

/// One window's page.
pub const WebView2 = struct {
    controller: ?*anyopaque = null,
    core: ?*anyopaque = null,
    environment: ?*anyopaque = null,
    /// The URL asked for before the controller existed.
    pending_url: [2048]u8 = undefined,
    pending_len: usize = 0,
    ready: bool = false,
    /// The HWND the controller is parented to, needed when it is created.
    hwnd: ffi.HWND = undefined,

    pub fn navigate(self: *WebView2, url: []const u8) Error!void {
        self.pending_len = @min(url.len, self.pending_url.len);
        @memcpy(self.pending_url[0..self.pending_len], url[0..self.pending_len]);
        if (!self.ready) return; // `onControllerReady` navigates instead
        evalNavigate(self) catch |e| return e;
    }

    pub fn eval(self: *WebView2, code: []const u8) Error!void {
        const core = self.core orelse return Error.NotSupported;
        var buf: [65536]u16 = undefined;
        const w = ffi.utf16(&buf, code) orelse return Error.ScriptFailed;
        const vtable = vtableOf(core);
        _ = vtable.ExecuteScript(core, w, null, null);
    }

    /// Adds a script that runs before any page script, which is how the IPC
    /// bridge reaches the page before its own code does.
    pub fn addScript(self: *WebView2, code: []const u8) Error!void {
        const core = self.core orelse return Error.NotSupported;
        var buf: [65536]u16 = undefined;
        const w = ffi.utf16(&buf, code) orelse return Error.ScriptFailed;
        const vtable = vtableOf(core);
        _ = vtable.AddScriptToExecuteOnDocumentCreated(core, w, null, null);
    }

    pub fn openDevtools(self: *WebView2) void {
        const core = self.core orelse return;
        const vtable = vtableOf(core);
        _ = vtable.OpenDevToolsWindow(core);
    }

    pub fn destroy(self: *WebView2) void {
        if (self.controller) |c| {
            const vtable = controllerVtableOf(c);
            _ = vtable.Close(c);
            _ = vtable.Release(c);
            self.controller = null;
        }
        self.core = null;
        self.ready = false;
    }
};

fn evalNavigate(self: *WebView2) Error!void {
    const core = self.core orelse return Error.NotSupported;
    var buf: [2048]u16 = undefined;
    const w = ffi.utf16(&buf, self.pending_url[0..self.pending_len]) orelse
        return Error.NavigationFailed;
    const vtable = vtableOf(core);
    _ = vtable.Navigate(core, w, null, null, null);
}

/// Creates the environment for one window; the controller follows asynchronously.
pub fn create(state: *@import("backend.zig").WindowState, hwnd: ffi.HWND) Error!*WebView2 {
    try loadLoader();

    const self = try std.heap.c_allocator.create(WebView2);
    self.* = .{ .hwnd = hwnd };

    const handler = try EnvironmentHandler.create(self);
    const hr = create_environment.?(null, null, @ptrCast(self), handler);
    if (hr < 0) {
        log.err("webview2: CreateCoreWebView2EnvironmentWithOptions failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        return Error.EnvironmentFailed;
    }
    _ = state;
    return self;
}

// ------------------------------------------------------------ COM vtables
//
// Only the slots MyZig calls are typed; the ones it does not call are left as
// `*const anyopaque` so the order is documented without inventing signatures.

const EnvironmentVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const anyopaque,
    CreateCoreWebView2Controller: *const fn (
        *anyopaque,
        ffi.HWND,
        *const ControllerHandler.Vtbl,
    ) callconv(ffi.WINAPI) ffi.HRESULT,
};

const ControllerVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(ffi.WINAPI) u32,
    get_IsVisible: *const anyopaque,
    put_IsVisible: *const anyopaque,
    get_Bounds: *const anyopaque,
    put_Bounds: *const anyopaque,
    get_ZoomFactor: *const anyopaque,
    put_ZoomFactor: *const anyopaque,
    add_ZoomFactorChanged: *const anyopaque,
    remove_ZoomFactorChanged: *const anyopaque,
    SetBoundsAndZoomFactor: *const anyopaque,
    MoveFocus: *const anyopaque,
    add_MoveFocusRequested: *const anyopaque,
    remove_MoveFocusRequested: *const anyopaque,
    add_GotFocus: *const anyopaque,
    remove_GotFocus: *const anyopaque,
    add_LostFocus: *const anyopaque,
    remove_LostFocus: *const anyopaque,
    add_AcceleratorKeyPressed: *const anyopaque,
    remove_AcceleratorKeyPressed: *const anyopaque,
    get_ParentWindow: *const anyopaque,
    put_ParentWindow: *const anyopaque,
    NotifyParentWindowPositionChanged: *const anyopaque,
    Close: *const fn (*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
    get_CoreWebView2: *const fn (*anyopaque, *?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
};

const CoreWebView2Vtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const anyopaque,
    get_Settings: *const anyopaque,
    get_Source: *const anyopaque,
    Navigate: *const fn (
        *anyopaque,
        [*:0]const u16,
        ?*anyopaque,
        ?*anyopaque,
        ?*anyopaque,
    ) callconv(ffi.WINAPI) ffi.HRESULT,
    NavigateToString: *const anyopaque,
    add_NavigationStarting: *const anyopaque,
    remove_NavigationStarting: *const anyopaque,
    add_ContentLoading: *const anyopaque,
    remove_ContentLoading: *const anyopaque,
    add_SourceChanged: *const anyopaque,
    remove_SourceChanged: *const anyopaque,
    add_HistoryChanged: *const anyopaque,
    remove_HistoryChanged: *const anyopaque,
    add_NavigationCompleted: *const anyopaque,
    remove_NavigationCompleted: *const anyopaque,
    add_FrameNavigationStarting: *const anyopaque,
    remove_FrameNavigationStarting: *const anyopaque,
    add_FrameNavigationCompleted: *const anyopaque,
    remove_FrameNavigationCompleted: *const anyopaque,
    add_ScriptDialogOpening: *const anyopaque,
    remove_ScriptDialogOpening: *const anyopaque,
    add_PermissionRequested: *const anyopaque,
    remove_PermissionRequested: *const anyopaque,
    add_ProcessFailed: *const anyopaque,
    remove_ProcessFailed: *const anyopaque,
    AddScriptToExecuteOnDocumentCreated: *const fn (
        *anyopaque,
        [*:0]const u16,
        ?*anyopaque,
        ?*anyopaque,
    ) callconv(ffi.WINAPI) ffi.HRESULT,
    ExecuteScript: *const fn (
        *anyopaque,
        [*:0]const u16,
        ?*anyopaque,
        ?*anyopaque,
    ) callconv(ffi.WINAPI) ffi.HRESULT,
    OpenDevToolsWindow: *const fn (*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
};

// ---------------------------------------------------------- COM handlers

/// The handler for `CreateCoreWebView2EnvironmentWithOptions`.
const EnvironmentHandler = struct {
    vtable: *const Vtbl,
    refs: u32,
    wv: *WebView2,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*anyopaque, *const ffi.GUID, *?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
        AddRef: *const fn (*anyopaque) callconv(ffi.WINAPI) u32,
        Release: *const fn (*anyopaque) callconv(ffi.WINAPI) u32,
        Invoke: *const fn (*anyopaque, ffi.HRESULT, ?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
    };

    const vtable_value = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    fn create(wv: *WebView2) Error!*const Vtbl {
        const o = std.heap.c_allocator.create(EnvironmentHandler) catch return Error.OutOfMemory;
        o.* = .{ .vtable = &vtable_value, .refs = 1, .wv = wv };
        return o.vtable;
    }

    fn queryInterface(_: *anyopaque, _: *const ffi.GUID, out: *?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT {
        out.* = null;
        return e_nointerface;
    }
    fn addRef(self: *anyopaque) callconv(ffi.WINAPI) u32 {
        const o: *EnvironmentHandler = @ptrCast(@alignCast(self));
        o.refs += 1;
        return o.refs;
    }
    fn release(self: *anyopaque) callconv(ffi.WINAPI) u32 {
        const o: *EnvironmentHandler = @ptrCast(@alignCast(self));
        o.refs -= 1;
        return o.refs;
    }

    fn invoke(self: *anyopaque, hr: ffi.HRESULT, environment: ?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT {
        const o: *EnvironmentHandler = @ptrCast(@alignCast(self));
        const env = environment orelse {
            log.err("webview2: no environment (0x{x})", .{@as(u32, @bitCast(hr))});
            return 0;
        };
        log.debug("webview2: environment ready", .{});
        o.wv.environment = env;

        const vtable = environmentVtableOf(env);
        const handler = ControllerHandler.create(o.wv) catch return 0;
        const rc = vtable.CreateCoreWebView2Controller(env, o.wv.hwnd, handler);
        if (rc < 0) {
            log.err("webview2: CreateCoreWebView2Controller failed: 0x{x}", .{@as(u32, @bitCast(rc))});
        }
        return 0;
    }
};

/// The handler for `CreateCoreWebView2Controller`.
const ControllerHandler = struct {
    vtable: *const Vtbl,
    refs: u32,
    wv: *WebView2,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*anyopaque, *const ffi.GUID, *?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
        AddRef: *const fn (*anyopaque) callconv(ffi.WINAPI) u32,
        Release: *const fn (*anyopaque) callconv(ffi.WINAPI) u32,
        Invoke: *const fn (*anyopaque, ffi.HRESULT, ?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT,
    };

    const vtable_value = Vtbl{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .Invoke = invoke,
    };

    fn create(wv: *WebView2) Error!*const Vtbl {
        const o = std.heap.c_allocator.create(ControllerHandler) catch return Error.OutOfMemory;
        o.* = .{ .vtable = &vtable_value, .refs = 1, .wv = wv };
        return o.vtable;
    }

    fn queryInterface(_: *anyopaque, _: *const ffi.GUID, out: *?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT {
        out.* = null;
        return e_nointerface;
    }
    fn addRef(self: *anyopaque) callconv(ffi.WINAPI) u32 {
        const o: *ControllerHandler = @ptrCast(@alignCast(self));
        o.refs += 1;
        return o.refs;
    }
    fn release(self: *anyopaque) callconv(ffi.WINAPI) u32 {
        const o: *ControllerHandler = @ptrCast(@alignCast(self));
        o.refs -= 1;
        return o.refs;
    }

    fn invoke(self: *anyopaque, hr: ffi.HRESULT, controller: ?*anyopaque) callconv(ffi.WINAPI) ffi.HRESULT {
        const o: *ControllerHandler = @ptrCast(@alignCast(self));
        const ctrl = controller orelse {
            log.err("webview2: no controller (0x{x})", .{@as(u32, @bitCast(hr))});
            return 0;
        };
        const wv = o.wv;
        wv.controller = ctrl;

        const vtable = controllerVtableOf(ctrl);
        var core: ?*anyopaque = null;
        if (vtable.get_CoreWebView2(ctrl, &core) < 0 or core == null) {
            log.err("webview2: the controller has no CoreWebView2", .{});
            return 0;
        }
        wv.core = core;
        wv.ready = true;

        // Now that the browser exists, the URL asked for earlier can load.
        if (wv.pending_len > 0) evalNavigate(wv) catch |e| {
            log.err("webview2: deferred navigation failed: {s}", .{@errorName(e)});
        };
        return 0;
    }
};

/// `E_NOINTERFACE`, written as its bit pattern because `HRESULT` is signed.
const e_nointerface: ffi.HRESULT = @bitCast(@as(u32, 0x80004002));

test "a missing loader is reported, not a crash" {
    loader = null;
    create_environment = null;
    if (loadLoader()) |_| {
        // The runtime is installed on this machine, which is not the case the
        // test is about; nothing to assert.
    } else |e| {
        try std.testing.expectEqual(Error.LoaderMissing, e);
    }
}

//! The Win32 declarations the Windows backend needs.
//!
//! Zig 0.17's `std.os.windows` ships a small subset of the Win32 API, so the
//! functions MyZig calls are declared here. Only what is used is declared: a
//! wrong signature is a link error rather than a silent misbehaviour, and an
//! unused declaration is one more thing to keep right.
//!
//! Everything is linked against the system libraries the linker already knows
//! about, so an application needs no extra build step.

const std = @import("std");

pub const HINSTANCE = *anyopaque;
pub const HWND = *anyopaque;
pub const HMENU = *anyopaque;
pub const HICON = *anyopaque;
pub const HCURSOR = *anyopaque;
pub const HBRUSH = *anyopaque;
pub const HFONT = *anyopaque;
pub const HBITMAP = *anyopaque;
pub const HDC = *anyopaque;
pub const HANDLE = *anyopaque;
pub const HMODULE = *anyopaque;
pub const LPVOID = ?*anyopaque;
pub const UINT = c_uint;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const ATOM = u16;
pub const DWORD = u32;
pub const BOOL = i32;
pub const LONG = i32;
pub const HRESULT = i32;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const WINAPI = std.builtin.CallingConvention.winapi;

// ---------------------------------------------------------------- constants

pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_OVERLAPPEDWINDOW: DWORD =
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_HIDE: i32 = 0;
pub const SW_SHOWNORMAL: i32 = 1;
pub const SW_SHOW: i32 = 5;
pub const SW_MAXIMIZE: i32 = 3;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_RESTORE: i32 = 9;

pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_SHOWWINDOW: UINT = 0x0018;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_APP: UINT = 0x8000;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_NCDESTROY: UINT = 0x0082;
pub const WM_DPICHANGED_AFTERPARENT: UINT = 0x02E3;

pub const PM_REMOVE: UINT = 0x0001;

pub const GWLP_USERDATA: c_int = -21;
pub const GWL_STYLE: c_int = -16;
pub const GWL_EXSTYLE: c_int = -20;
pub const GWLP_WNDPROC: c_int = -4;

pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;

pub const HWND_TOP: ?HWND = null;
pub const HWND_TOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

pub const MB_OK: UINT = 0x00000000;
pub const MB_YESNO: UINT = 0x00000004;
pub const MB_ICONINFORMATION: UINT = 0x00000040;
pub const MB_ICONWARNING: UINT = 0x00000030;
pub const MB_ICONQUESTION: UINT = 0x00000020;
pub const MB_ICONERROR: UINT = 0x00000010;
pub const MB_TOPMOST: UINT = 0x00040000;
pub const IDOK: c_int = 1;
pub const IDYES: c_int = 6;
pub const IDNO: c_int = 7;

pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

pub const MF_STRING: UINT = 0x00000000;
pub const MF_SEPARATOR: UINT = 0x00000800;
pub const MF_POPUP: UINT = 0x00000010;
pub const MF_CHECKED: UINT = 0x00000008;
pub const MF_GRAYED: UINT = 0x00000001;

pub const IDC_ARROW: usize = 32512;

pub const SM_CXSCREEN: c_int = 0;
pub const SM_CYSCREEN: c_int = 1;
pub const SM_CXDRAG: c_int = 68;

pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
pub const MONITORINFOF_PRIMARY: DWORD = 1;

pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

// ------------------------------------------------------------------- types

pub const POINT = extern struct {
    x: LONG = 0,
    y: LONG = 0,
};
pub const RECT = extern struct {
    left: LONG = 0,
    top: LONG = 0,
    right: LONG = 0,
    bottom: LONG = 0,
};
pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};
pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: ?[*:0]const u16 = null,
    hIconSm: ?HICON = null,
};
pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = @splat(0),
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG = 0,
    biHeight: LONG = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT = .{},
    ptMaxSize: POINT = .{},
    ptMaxPosition: POINT = .{},
    ptMinTrackSize: POINT = .{},
    ptMaxTrackSize: POINT = .{},
};

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

// ----------------------------------------------------------------- imports

// user32 -------------------------------------------------------------------
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) ATOM;
pub extern "user32" fn UnregisterClassW([*:0]const u16, ?HINSTANCE) callconv(WINAPI) BOOL;
pub extern "user32" fn CreateWindowExW(
    DWORD,
    [*:0]const u16,
    [*:0]const u16,
    DWORD,
    c_int,
    c_int,
    c_int,
    c_int,
    ?HWND,
    ?HMENU,
    ?HINSTANCE,
    LPVOID,
) callconv(WINAPI) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(WINAPI) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(WINAPI) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(WINAPI) isize;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostQuitMessage(c_int) callconv(WINAPI) void;
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn GetSystemMetrics(c_int) callconv(WINAPI) c_int;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(WINAPI) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDC(?HWND) callconv(WINAPI) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, ?HDC) callconv(WINAPI) c_int;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(WINAPI) ?HMENU;
pub extern "user32" fn AppendMenuW(HMENU, UINT, usize, ?[*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn SetMenu(HWND, ?HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn DestroyMenu(HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn DrawMenuBar(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*const anyopaque) callconv(WINAPI) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(WINAPI) BOOL;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, UINT) callconv(WINAPI) c_int;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(WINAPI) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(?*anyopaque) callconv(WINAPI) BOOL;
pub extern "user32" fn EnumDisplayMonitors(?HDC, ?*const RECT, MONITORENUMPROC, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMonitorInfoW(?*anyopaque, *MONITORINFO) callconv(WINAPI) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(WINAPI) ?*anyopaque;
pub extern "user32" fn AdjustWindowRectEx(*RECT, DWORD, BOOL, DWORD) callconv(WINAPI) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(WINAPI) BOOL;
pub const MONITORENUMPROC = *const fn (?*anyopaque, ?HDC, *RECT, LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn RegisterWindowMessageW([*:0]const u16) callconv(WINAPI) UINT;
pub extern "user32" fn GetCursorPos(*POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn IsZoomed(HWND) callconv(WINAPI) BOOL;

// gdi32 --------------------------------------------------------------------
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(WINAPI) ?HDC;
pub extern "gdi32" fn CreateDIBSection(
    ?HDC,
    *const BITMAPINFOHEADER,
    UINT,
    *?*anyopaque,
    ?HANDLE,
    DWORD,
) callconv(WINAPI) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, ?*anyopaque) callconv(WINAPI) ?*anyopaque;
pub extern "gdi32" fn DeleteObject(?*anyopaque) callconv(WINAPI) BOOL;
pub extern "gdi32" fn DeleteDC(HDC) callconv(WINAPI) BOOL;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, ?HDC, c_int, c_int, DWORD) callconv(WINAPI) BOOL;
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: UINT = 0;

// kernel32 -----------------------------------------------------------------
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) DWORD;
pub extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(WINAPI) ?*const anyopaque;
pub extern "kernel32" fn FreeLibrary(HMODULE) callconv(WINAPI) BOOL;

// clipboard ----------------------------------------------------------------
pub extern "user32" fn OpenClipboard(?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn GetClipboardData(UINT) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(WINAPI) BOOL;

// heap ---------------------------------------------------------------------
pub extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn GlobalLock(HANDLE) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GlobalFree(HANDLE) callconv(WINAPI) ?HANDLE;

// comdlg32 -----------------------------------------------------------------
/// `OPENFILENAMEW`. `lStructSize` must be set to `@sizeOf` this struct or the
/// call fails with no explanation.
pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*:0]u16 = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 0,
    lpstrFile: [*:0]u16 = undefined,
    nMaxFile: DWORD = 0,
    lpstrFileTitle: ?[*:0]u16 = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: DWORD = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};

pub extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(WINAPI) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(WINAPI) BOOL;

pub const OFN_READONLY: DWORD = 0x0000_0001;
pub const OFN_OVERWRITEPROMPT: DWORD = 0x0000_0002;
pub const OFN_NOCHANGEDIR: DWORD = 0x0000_0008;
pub const OFN_PATHMUSTEXIST: DWORD = 0x0000_0800;
pub const OFN_FILEMUSTEXIST: DWORD = 0x0000_1000;
pub const OFN_ALLOWMULTISELECT: DWORD = 0x0000_0200;
pub const OFN_EXPLORER: DWORD = 0x0008_0000;

// hotkeys ------------------------------------------------------------------
pub extern "user32" fn RegisterHotKey(?HWND, c_int, UINT, UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn UnregisterHotKey(?HWND, c_int) callconv(WINAPI) BOOL;

/// `MOD_*` masks. These are the opposite convention to the `WM_KEYDOWN`
/// modifiers: `MOD_ALT` is 1, not a bit far up, and `MOD_WIN` is 8.
pub const MOD_ALT: UINT = 0x0001;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_WIN: UINT = 0x0008;
/// Stops the chord reaching the focused application; MyZig does not set it, so
/// a shortcut does not swallow the key for everyone else.
pub const MOD_NOREPEAT: UINT = 0x4000;

/// `WM_HOTKEY` is posted to the thread's message queue with the hotkey's id in
/// `wparam`.
pub const WM_HOTKEY: UINT = 0x0312;

/// `ERROR_HOTKEY_ALREADY_REGISTERED`, which `RegisterHotKey` reports through
/// `GetLastError` rather than as its return value.
pub const ERROR_HOTKEY_ALREADY_REGISTERED: i32 = 1409;

pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;

/// Virtual-key codes. These are ASCII for the letters and digits, which is the
/// one place Win32 is kinder than Carbon, but the named keys are not.
pub const VK_BACK: UINT = 0x08;
pub const VK_TAB: UINT = 0x09;
pub const VK_RETURN: UINT = 0x0D;
pub const VK_ESCAPE: UINT = 0x1B;
pub const VK_SPACE: UINT = 0x20;
pub const VK_PRIOR: UINT = 0x21; // Page Up
pub const VK_NEXT: UINT = 0x22; // Page Down
pub const VK_END: UINT = 0x23; // End
pub const VK_HOME: UINT = 0x24; // Home
pub const VK_LEFT: UINT = 0x25;
pub const VK_UP: UINT = 0x26;
pub const VK_RIGHT: UINT = 0x27;
pub const VK_DOWN: UINT = 0x28;
pub const VK_INSERT: UINT = 0x2D;
pub const VK_DELETE: UINT = 0x2E;
pub const VK_F1: UINT = 0x70;

// tray ---------------------------------------------------------------------
/// `NOTIFYICONDATAW`. `cbSize` must be `@sizeOf` this struct, and the version
/// field decides which tail fields Windows reads. It is set to the newest
/// layout these declarations describe, so every field below is honoured.
pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]u16,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = @splat(0),
    /// The timeout, unioned with the version marker. Zero means the version
    /// tied to `cbSize`, so the plain timeout is what is written.
    uTimeoutOrVersion: UINT = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = @splat(0) },
    hBalloonIcon: ?HICON = null,
};

pub extern "shell32" fn Shell_NotifyIconW(DWORD, *NOTIFYICONDATAW) callconv(WINAPI) BOOL;
pub extern "shell32" fn ExtractIconExW(
    [*:0]const u16,
    c_int,
    ?*?HICON,
    ?*?HICON,
    UINT,
) callconv(WINAPI) UINT;

pub extern "user32" fn LoadIconW(?HINSTANCE, ?[*:0]const u16) callconv(WINAPI) ?HICON;
pub extern "user32" fn DestroyIcon(?HICON) callconv(WINAPI) BOOL;
/// `NOTIFYICONDATAW` flags.
pub const NIF_MESSAGE: UINT = 0x0000_0001;
pub const NIF_ICON: UINT = 0x0000_0002;
pub const NIF_TIP: UINT = 0x0000_0004;
pub const NIF_INFO: UINT = 0x0000_0010;
pub const NIF_SHOWTIP: UINT = 0x0000_0080;

/// `Shell_NotifyIconW` messages.
pub const NIM_ADD: DWORD = 0x0000_0000;
pub const NIM_MODIFY: DWORD = 0x0000_0001;
pub const NIM_DELETE: DWORD = 0x0000_0002;
pub const NIM_SETVERSION: DWORD = 0x0000_0004;

/// The balloon icon kinds.
pub const NIIF_NONE: DWORD = 0x0000_0000;
pub const NIIF_INFO: DWORD = 0x0000_0001;
pub const NIIF_WARNING: DWORD = 0x0000_0002;
pub const NIIF_ERROR: DWORD = 0x0000_0003;
pub const NIIF_NOSOUND: DWORD = 0x0000_0010;

/// The notification-version marker for `uTimeoutOrVersion`, which selects the
/// layout Windows reads.
pub const NOTIFYICON_VERSION_4: UINT = 4;

/// `IDI_APPLICATION`, the fallback icon when the caller names none.
pub const IDI_APPLICATION_RESOURCE: usize = 32512;
/// The one-`LOWORD`-full idiom for `MAKEINTRESOURCE(IDI_APPLICATION)`.
pub const IDI_APPLICATION: [*:0]const u16 = @ptrFromInt(32512);

/// The tray callback message. `WM_APP + n` so it cannot collide with a Win32
/// message; the exact offset is MyZig's choice as long as nothing else uses it.
pub const WM_MYZIG_TRAY: UINT = 0x8000 + 2;

/// `NIN_SELECT` and the right-click message Windows sends to the tray window.
pub const NIN_SELECT: UINT = 0x0400;
pub const WM_CONTEXTMENU: UINT = 0x007B;

/// `SendMessageTimeout` flags used to broadcast a taskbar-restart notice.
pub const WM_TASKBARCREATED_KEY: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated");

// shell32 ------------------------------------------------------------------
pub extern "shell32" fn ShellExecuteW(
    ?HWND,
    [*:0]const u16,
    [*:0]const u16,
    ?[*:0]const u16,
    ?[*:0]const u16,
    c_int,
) callconv(WINAPI) ?HINSTANCE;
pub extern "shell32" fn SHOpenFolderAndSelectItems(
    ?*anyopaque,
    UINT,
    ?*const anyopaque,
    DWORD,
) callconv(WINAPI) HRESULT;

// ole32 --------------------------------------------------------------------
pub extern "ole32" fn OleInitialize(?*anyopaque) callconv(WINAPI) HRESULT;
pub extern "ole32" fn OleUninitialize() callconv(WINAPI) void;
pub extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(WINAPI) void;

// ------------------------------------------------------------------ helpers

/// Encodes a UTF-8 slice into a caller-provided NUL-terminated UTF-16 buffer.
///
/// Win32's wide APIs take UTF-16, and every string MyZig hands them is short —
/// a title, a URL, a menu label — so a caller buffer is cheaper than an
/// allocation.
///
/// The buffer is checked first, because `std.unicode.utf8ToUtf16Le` documents
/// that it "assumes there is enough space": with a short slice it writes past
/// the end and aborts rather than returning an error. An earlier version of
/// this function relied on that assumed error and crashed in its own test.
pub fn utf16(buf: []u16, s: []const u8) ?[*:0]const u16 {
    if (buf.len == 0) return null;
    const room = buf.len - 1;

    // An upper bound on the code units needed: every UTF-8 byte becomes at
    // most one UTF-16 unit, except a 4-byte sequence, which becomes two. So
    // the count is never more than the byte length.
    if (s.len > room) {
        // The real count may still fit when the extra bytes were continuation
        // bytes, so it is computed exactly rather than rejected outright.
        const needed = utf16Len(s) orelse return null;
        if (needed > room) return null;
    }

    const n = std.unicode.utf8ToUtf16Le(buf[0..room], s) catch return null;
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// How many UTF-16 code units `s` needs, or null when it is not valid UTF-8.
///
/// A rune outside the BMP needs two units, which is the whole reason a byte
/// count is not an answer.
pub fn utf16Len(s: []const u8) ?usize {
    var units: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        units += if (cp > 0xFFFF) 2 else 1;
    }
    return units;
}

/// The inverse, for reading a string back out of Win32.
pub fn utf8(buf: []u8, s: []const u16) ?[]const u8 {
    const len = std.mem.indexOfScalar(u16, s, 0) orelse s.len;
    const n = std.unicode.utf16LeToUtf8(buf, s[0..len]) catch return null;
    return buf[0..n];
}

test "a string round trips through utf16" {
    var wide: [64]u16 = undefined;
    const w = utf16(&wide, "hello world").?;
    try std.testing.expectEqual(@as(u16, 0), wide[11]);

    var back: [64]u8 = undefined;
    const s = utf8(&back, std.mem.span(w)).?;
    try std.testing.expectEqualStrings("hello world", s);
}

test "non-ascii survives the round trip" {
    var wide: [64]u16 = undefined;
    const w = utf16(&wide, "çalışma — 日本語").?;

    var back: [64]u8 = undefined;
    const s = utf8(&back, std.mem.span(w)).?;
    try std.testing.expectEqualStrings("çalışma — 日本語", s);
}

test "a buffer too small is rejected rather than truncated" {
    var wide: [2]u16 = undefined;
    // One code unit of room plus the terminator cannot hold this.
    try std.testing.expect(utf16(&wide, "hello") == null);
}

test "a rune outside the BMP needs two units, not one" {
    // U+1F600 is four UTF-8 bytes and two UTF-16 units. A byte count would
    // over-estimate the room needed; a codepoint count would under-estimate it
    // by one and write past the end.
    try std.testing.expectEqual(@as(?usize, 2), utf16Len("😀"));
    try std.testing.expectEqual(@as(?usize, 4), utf16Len("a😀b"));

    // Exactly enough room, including the terminator.
    var exact: [3]u16 = undefined;
    const w = utf16(&exact, "😀").?;
    try std.testing.expectEqual(@as(usize, 2), std.mem.len(w));

    // One unit short is refused rather than overflowing.
    var short: [2]u16 = undefined;
    try std.testing.expect(utf16(&short, "😀") == null);
}

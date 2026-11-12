//! MyZig — a desktop application framework for Zig.
//!
//! MyZig builds native desktop applications in Zig with no garbage collector
//! and no runtime to install. A window can show:
//!
//! * **A web page** in the webview the operating system already has —
//!   WebKitGTK on Linux, WebView2 on Windows, WKWebView on macOS — whose
//!   frontend calls Zig services through a typed IPC layer and a TypeScript
//!   client generated from the Zig declarations.
//! * **Native UI** written in Zig and drawn by MyZig on the GPU, with no HTML,
//!   no JavaScript and no webview process.
//!
//! One application, or one window, can mix the two.
//!
//! ## Minimal application
//!
//! ```zig
//! const myzig = @import("myzig");
//!
//! pub fn main() !void {
//!     var app = try myzig.App.init(.{ .name = "Hello" });
//!     defer app.deinit();
//!
//!     _ = try app.createWindow(.{
//!         .title = "Hello MyZig",
//!         .width = 900,
//!         .height = 600,
//!         .url = "myzig://localhost/index.html",
//!     });
//!
//!     try app.run();
//! }
//! ```
//!
//! ## Threading
//!
//! `App.run` must be called from the process' main thread, because the native
//! GUI toolkits require it. Every other public function is safe to call from
//! any thread: calls that need the main thread are posted to it and, where the
//! result is needed, wait for it. Listeners run on the main thread; IPC
//! handlers run on their own threads and may block.
//!
//! ## Ownership
//!
//! MyZig has no garbage collector. Every allocator MyZig uses comes from the
//! one handed to `App.init`. Memory MyZig allocates for you is freed by the
//! value that owns it; see docs/memory-management.md and the doc comments on
//! each API.

const std = @import("std");

// --------------------------------------------------------------- core types
pub const App = @import("app.zig").App;
pub const AppOptions = @import("app.zig").AppOptions;
pub const FrontendFile = @import("app.zig").FrontendFile;
pub const default_frontend_url = @import("app.zig").default_frontend_url;
pub const Phase = @import("app.zig").Phase;
pub const Window = @import("window.zig").Window;
pub const WindowOptions = @import("window.zig").WindowOptions;
pub const Rect = @import("window.zig").Rect;
pub const Point = @import("window.zig").Point;
pub const Size = @import("window.zig").Size;

// --------------------------------------------------------------- subsystems
pub const ipc = @import("ipc/ipc.zig");
pub const webview = @import("webview/webview.zig");
pub const ui = @import("ui/ui.zig");
pub const desktop = @import("desktop/desktop.zig");
pub const plugins = @import("plugins/plugins.zig");
pub const platform = @import("platform/platform.zig");

// ------------------------------------------------------------------ support
pub const events = @import("events.zig");
pub const menu = @import("menu.zig");
pub const Menu = @import("menu.zig").Menu;
pub const MenuItem = @import("menu.zig").Item;
pub const Accelerator = @import("menu.zig").Accelerator;
pub const allocator = @import("allocator.zig");
pub const json = @import("json.zig");
pub const errors = @import("errors.zig");
pub const log = @import("log.zig");
pub const loop = @import("loop.zig");
pub const paths = @import("utils/paths.zig");
pub const env = @import("utils/env.zig");
pub const version = @import("version.zig").version_string;

// ------------------------------------------------------------ convenience
/// The framework's version as a semantic version value.
pub const semantic_version = @import("version.zig").semver;

test {
    // Pull every module's tests into `zig build test`.
    std.testing.refAllDecls(@This());
    _ = @import("app.zig");
    _ = @import("window.zig");
    _ = @import("events.zig");
    _ = @import("allocator.zig");
    _ = @import("json.zig");
    _ = @import("errors.zig");
    _ = @import("log.zig");
    _ = @import("loop.zig");
    _ = @import("version.zig");
    _ = @import("utils/paths.zig");
    _ = @import("utils/env.zig");
    _ = @import("utils/strings.zig");
    _ = @import("ipc/ipc.zig");
    _ = @import("webview/webview.zig");
    _ = @import("desktop/desktop.zig");
    _ = @import("plugins/plugins.zig");
    _ = @import("platform/linux/ffi.zig");
}

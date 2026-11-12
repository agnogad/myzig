# MyZig

A desktop application framework for Zig. No garbage collector, no runtime to
install, no JavaScript toolchain required.

A window can show:

* **A web page** in the webview the operating system already has — WebKitGTK on
  Linux, WebView2 on Windows, WKWebView on macOS — whose frontend calls Zig
  services through a typed IPC layer and a TypeScript client generated from the
  Zig declarations.
* **Native UI** written in Zig and drawn by MyZig, with no HTML, no JavaScript
  and no webview process.
* **Both**, in one application or one window.

```zig
const myzig = @import("myzig");

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();

    var app = try myzig.App.init(gpa_state.allocator(), .{ .name = "Hello" });
    defer app.deinit();

    _ = try app.createWindow(.{
        .title = "Hello MyZig",
        .width = 900,
        .height = 600,
        .url = "myzig://app/index.html",
    });

    try app.run();
}
```

## Status

Linux is the supported platform today, and it is the only one anything has been
run on. The Windows and macOS backends are written and compile for their
targets, but no one has run them: they are not claimed to work, and
`docs/platforms.md` lists each feature that is missing rather than pretending
otherwise.

| Area | State |
| --- | --- |
| Windows, WebKitGTK pages, `myzig://` scheme | works |
| Typed IPC, events, TypeScript client generation | works |
| Clipboard, dialogs, notifications, menus, tray, global shortcuts | works |
| Native UI: layout, software rasteriser, bitmap text, mouse input | works |
| Plugins | works |
| `myzig` command line: `new`, `generate`, `package`, `package --deb`, `doctor` | works |
| Windows backend (Win32 + WebView2) | compiles for Windows, never run |
| macOS backend (AppKit + WKWebView) | compiles for macOS, never run |
| Accessibility (AT-SPI) | done on Linux; not on Windows or macOS |
| GPU rendering, text beyond Latin-1 | not started |

## Requirements

* Zig 0.17.1
* Linux: GTK 3, WebKitGTK 4.1, cairo, X11 or Wayland

MyZig loads GTK, WebKitGTK, cairo and X11 **at runtime** with `std.DynLib`. A
native-only application never maps a web engine; a page-only application never
maps cairo. `myzig doctor` reports which libraries are present.

## Install

```sh
git clone https://github.com/your-org/myzig
cd myzig
zig build install
```

That puts `myzig` in `zig-out/bin`. Add it to `PATH`, or point `MYZIG_HOME` at
the checkout:

```sh
export MYZIG_HOME=$PWD
```

## Create a project

```sh
myzig new myapp            # a web-frontend application
myzig new myapp --native   # a native-UI application
cd myapp
zig build run
```

The generated manifest points at the framework checkout, so a new project
builds without a package registry.

## Documentation

* [Getting started](docs/getting-started.md) — a first application, step by step.
* [IPC](docs/ipc.md) — services, events, error codes, the TypeScript client.
* [Native UI](docs/native-ui.md) — layout, drawing, input, text.
* [Accessibility](docs/accessibility.md) — describing a native window to a
  screen reader.
* [Plugins](docs/plugins.md) — packaging services and lifecycle hooks.
* [Memory management](docs/memory-management.md) — who owns what.
* [Platforms](docs/platforms.md) — what each backend supports.
* [Packaging](docs/packaging.md) — `myzig package`, desktop entries, what is
  not built yet.
* [Progress](docs/PROGRESS.md) — milestones and what is verified.

## Examples

Ten programs in `examples/`, all built by `zig build`:

| Example | Shows |
| --- | --- |
| `hello-window` | an empty window |
| `hello-webview` | a page served from the binary |
| `ipc-greeter` | typed calls and events in both directions |
| `desktop-api` | clipboard, dialogs, notifications |
| `menus` | a native menu bar |
| `tray` | a status-area icon |
| `native-ui` | the native toolkit, drawn and clicked |
| `counter-native` | a native counter with buttons |
| `hybrid` | a native window beside a web window |
| `plugins` | a plugin that binds a service and owns a thread |

## Tests

```sh
zig build test --summary all
```

The suite runs against an in-memory backend, so it needs no display.

## Licence

MIT.

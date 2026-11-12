# MyZig progress

MyZig is a desktop application framework written in Zig, for web-based and
native-UI apps, on Linux, Windows and macOS. This file records what is built,
what is verified, and what is next. It is deliberately blunt: a feature appears
here only once it compiles, has tests, and has been run.

**Zig version:** 0.17.1

## Status

| Milestone | Scope | State |
| --- | --- | --- |
| 0 | Core: allocators, JSON, main-thread loop, app lifecycle, testing backend | **Done** |
| 1 | Linux backend: GTK 3 windows, WebKitGTK pages, `myzig://` scheme, bridge injection | **Done** |
| 2 | Typed IPC: service binding, events, TypeScript client generation | **Mostly done** (TS generation pending) |
| 3 | Desktop APIs: clipboard, dialogs, notifications, tray, menus, shortcuts | **In progress** (clipboard, dialogs, notifications done) |
| 4 | Native UI toolkit: layout, GPU rendering, accessibility | Not started |
| 5 | Windows backend: Win32 + WebView2 | Not started |
| 6 | macOS backend: AppKit + WKWebView | Not started |
| 7 | Ecosystem: CLI, plugins, packaging, auto-update | Not started |

## What works today

Verified by running the examples, not by reading the code:

* `App.init` / `app.run` / `App.deinit` with `DebugAllocator` reporting **no
  leaks** in every test and example.
* Windows open at the requested size, with the requested title, on X11.
  Verified with `xdotool getwindowgeometry`: a 720x480 request produced a
  720x480 window.
* A window with a `url` gets a real `WebKitWebView`; a page loaded over
  `myzig://` renders, including CSS from a second embedded file.
* The IPC bridge is injected at document start, top frame only. A page reading
  `window.myzig.windowId` gets the framework's window id.
* Runtime symbol loading: MyZig links no GTK or WebKit. `hello-window` never
  maps WebKitGTK; `hello-webview` does, on demand.
* Missing libraries produce a named error, not a loader crash before `main`.
* **Typed IPC round trip, live**: `ipc-greeter`'s page called
  `Greeter.greet("Ada")` and rendered the Zig reply
  `Hello, Ada! You are greeting #1.` in a real window.
* **Built-in desktop services, live** in `desktop-api`:
  `clipboard.writeText` → `copied 17 characters`,
  `clipboard.readText` → the same text back, and
  `App.info` → `{"name":"Desktop API","id":"dev.myzig.desktop-api","dev":true}`.
* A window created with an embedded `frontend` and no `url` serves
  `myzig://app/index.html` automatically.
* A page's `console.log` reaches the terminal, so the JavaScript side can be
  debugged without a screen.

## What is stubbed

These compile and run but do not yet do their job. Each says so in its own
source file and in the example that exercises it:

* TypeScript client generation and `myzig generate` (the last piece of
  milestone 2). Calls, events, subscriptions and cancellation all work.
* File and message dialogs and notifications are implemented but not yet
  verified on screen: they block on user input, so the test scripts check
  compilation and the call path rather than clicking them.
* Tray icons, menus and global shortcuts (milestone 3).
* Native UI rendering (milestone 4).
* Native UI: `counter-native` opens a window and prints that the toolkit is not
  there yet (milestone 4).
* The Windows and macOS backends return `NotSupported` from every entry point.

## Test suite

`zig build test` runs with the `testing` backend, so it needs no display:

```sh
zig build test --summary all
```

Covered: JSON parse/encode round trips and malformed input, allocator tiers,
path resolution, environment access, the page bridge template substitution,
URL path normalisation for the `myzig://` scheme, window handle generation
safety, and the full app lifecycle against the in-memory backend.

The GUI paths are verified by running them:

```sh
Xvfb :99 -screen 0 1280x800x24 &
env -u WAYLAND_DISPLAY DISPLAY=:99 GDK_BACKEND=x11 ./zig-out/bin/hello-webview
```

## Known limitations

* **Wayland**: window position, always-on-top and taskbar skipping are X11
  features. On Wayland they are best effort, and `setBounds` only resizes.
* **WebKitGTK DMA-BUF**: the renderer is disabled by default
  (`WEBKIT_DISABLE_DMABUF_RENDERER=1`) because it draws blank pages on NVIDIA,
  in VMs and in containers. Set the variable yourself to opt back in.
* **Single-instance** is parsed from options but not enforced yet.
* **Window state persistence** (`state_key`) is read but not written back.

## Next

1. Milestone 2: `App.bind` a service, route calls by window, reply with
   typed JSON, emit events, and generate the TypeScript client from the service
   definitions so the two sides cannot drift.

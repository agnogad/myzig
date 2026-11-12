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
| 2 | Typed IPC: service binding, events, TypeScript client generation | **Done** |
| 3 | Desktop APIs: clipboard, dialogs, notifications, tray, menus, shortcuts | **Done** |
| 4 | Native UI toolkit: layout, rendering, accessibility | **In progress** (layout, rasteriser, input and AT-SPI done; Unicode text is Latin-1 only) |
| 5 | Command line: `new`, `generate`, `doctor` | **Done** |
| 6 | Windows backend: Win32 + WebView2 | **Written, compiles for Windows, not yet run** |
| 7 | macOS backend: AppKit + WKWebView | Not started |
| 8 | Ecosystem: plugins, packaging, auto-update | **In progress** (plugins and `myzig package` done; auto-update not started) |

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
* **Menus, live**: `menus` builds File/View/Theme/Help from a portable model;
  the bar is drawn, opens, shows its accelerators (Ctrl+N, Ctrl+O, Ctrl+Q), and
  a click arrives in the page as `menu:command` with the Zig-side id.
* **A message box, live**: `desktop-api` opened a `Dialog.message`; the answer
  came back to the page (`dismissed` on Escape).
* **A global shortcut, live**: `tray` bound `Ctrl+Alt+T` through an X11 key
  grab and reported `bound`.
* **The tray, honestly**: under Xvfb there is no status area, so `createTray`
  returned false and the example printed `not shown (no status area)` instead of
  pretending the icon exists.
* **`myzig generate`** writes `myzig-client.d.ts`; the output compiles under
  `tsc --strict --noEmit`.

## What is stubbed

These compile and run but do not yet do their job. Each says so in its own
source file and in the example that exercises it:

* Notifications are built on `notify-send`; a desktop without a notification
  daemon gets `false`, not a silent drop. Not yet verified on a real session.
* Global shortcuts are X11 only. Wayland forbids global grabs by design, so
  `registerShortcut` returns `error.NotSupported` there.
## The application example

`examples/notes` is a complete program — persistent notes, a menu bar, a tray
icon and typed IPC — written to be the thing the framework is judged against.
It found five bugs and two genuinely missing APIs (`App.listen`,
`AppOptions.io`); see the commit log for the list.

## Milestone 4: the native UI toolkit

A window can now be drawn entirely by MyZig, with no page and no WebKit.

* `src/ui/geometry.zig` — rectangles, edge insets and colours, with
  source-over blending. Integer coordinates only: adding `f32` sizes down a tree
  drifts, and a row of boxes that should line up ends up a pixel off.
* `src/ui/layout.zig` — a flex-style engine. A box lays its children out in a
  row or a column with padding, spacing, fixed or content-derived sizes and a
  grow factor. Measured first, arranged second. Leftover space is divided by
  grow factor and the rounding remainder goes to the earliest children, so the
  frames add up to the parent exactly.
* `src/ui/canvas.zig` — a display list (`fill`, `text`) plus a software
  rasteriser, and `src/ui/font8x8.zig`, a bitmap font for ASCII 32–126. A
  bitmap font needs no font-file parser and no shaping, so text appears with no
  dependency at all.
* `src/platform/linux/surface.zig` — the Linux native window: a
  `GtkDrawingArea` inside a `GtkEventBox`, rasterised into an RGBA buffer and
  blitted through cairo. `cairo` is loaded at runtime like GTK, so a
  page-only application never maps it.

**Verified on screen**, not just compiled: `counter-native` draws a counter and
three buttons; three presses of `+1` printed `value = 1`, `2`, `3` and the
screenshot showed a large `3`. `native-ui` opens a 720×260 window
with a blue header, a counter and three buttons. Clicking `+1` twice and then
`Theme` printed `clicks = 2, dark = true`, and the next screenshot showed a
dark background and a highlighted Theme button. No web engine was loaded.

Three real bugs came out of running it:

1. **Text was garbage** because the builder stored the caller's slice. A draw
   function formats a number into a stack buffer, the frame is rasterised after
   it returns, and the buffer was already gone. The builder now copies text.
2. **Red and blue were swapped** because cairo's `ARGB32` is BGRA in memory. The
   header came out orange until the bytes were swapped before the blit.
3. **Clicks never arrived** because a `GtkDrawingArea` has no `GdkWindow` of its
   own. Wrapping it in a `GtkEventBox` gave it one.

Still open in this milestone: accessibility (exposing the tree to AT-SPI),
GPU rendering, and text beyond ASCII.
* Native UI is available: `counter-native` and `native-ui` draw and take input
  with no web engine loaded.
* The Windows backend is written and compiles for `x86_64-windows-gnu`, but
  **has never been run**: there is no Windows machine here. Win32 windows,
  menus, DPI awareness, the software-rasterised surface, monitor enumeration
  and the COM plumbing that brings up WebView2 are all present. Until someone
  runs it on Windows, treat it as unverified.
* The macOS backend returns `NotSupported` from every entry point.

## Milestone 5: the `myzig` command line

`myzig new NAME [--web|--native]` writes a project that builds and runs.
`myzig generate --out FILE` writes the TypeScript client; the declaration
passes `tsc --strict --noEmit`. `myzig doctor` reports the Zig version, the
target and which native libraries are present.

A generated project was built and run end to end: the page called
`Hello.greet("MyZig")` through the bridge and printed `Hello, MyZig!`.

Three bugs were fixed by actually running it:

1. **Every reply was a syntax error in the page.** The batch builder opened a
   JSON array that nothing closed, so the page received `receive([{...})`. The
   page reported it as a `SyntaxError` at `index.html:1`, which pointed at the
   bridge rather than at the reply. The brackets now live in one place.
2. **The manifest fingerprint halves were swapped.** `zig build` rejected every
   generated project and printed the value it wanted. The crc goes high, the id
   low.
3. **The dependency path was a hardcoded `../myzig`.** The framework checkout is
   now found from `MYZIG_HOME` or the executable's parents and written relative
   to the new project, since Zig rejects an absolute path in a manifest.

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

# Platforms

MyZig has one public API and one backend per operating system. This file records
what each backend actually does, so an application can check before relying on
something.

**Verified** means the behaviour was observed on a running program, not that the
code compiles.

## Linux

Backend: `src/platform/linux/`. GTK 3 for windows, menus and the tray;
WebKitGTK 4.1 for pages; cairo for the native surface; X11 for global shortcuts.

| Feature | State | Notes |
| --- | --- | --- |
| Windows, resize, close | verified | GTK 3 |
| Web pages | verified | WebKitGTK 4.1 |
| `myzig://` scheme | verified | registered before the first page |
| Typed IPC | verified | round trip with values and errors |
| Events to the page | verified | including from a plugin thread |
| Clipboard | verified | GTK selection |
| File dialogs | verified | GTK dialog |
| Message boxes | verified | GTK dialog |
| Notifications | verified | `notify-send` fallback under Xvfb |
| Menu bar | verified | GtkMenuBar |
| Tray icon | **not shown** | needs a status area; reported honestly as false when absent |
| Global shortcuts | verified | X11 key grab; Wayland refuses them with `NotSupported`, by design |
| Native UI surface | verified | GTK drawing area, software rasteriser |
| Native UI input | verified | mouse press and release |
| Accessibility | verified | AT-SPI over D-Bus: a reader walks the tree |
| Wayland session | verified | a whole window, drawn and legible, captured with `grim` |
| Window geometry persistence | verified | `window-state.json`; a saved 777×555 window opened at 777×555 |
| Single instance | verified | `flock`; a second copy logs `already running` and exits |

Libraries are loaded with `std.DynLib` at the moment a feature needs them:

| Library | Mapped when |
| --- | --- |
| `libgtk-3.so.0` | any window is created |
| `libwebkit2gtk-4.1.so.0` | the first page window is created |
| `libcairo.so.2` | the first native surface is created |
| `libX11.so.6` | the first global shortcut is bound |
| `libdbus-1.so.3` | a window first publishes an accessibility tree |
| `libappindicator3.so.1` | a tray is asked for on a desktop with no XEmbed status area |

So a native-only application never maps a web engine, and a page-only
application never maps cairo.

### Headless and CI

Linux runs under `Xvfb` for tests and screenshots:

```sh
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE GDK_BACKEND=x11 \
    WEBKIT_DISABLE_COMPOSITING_MODE=1 ./zig-out/bin/myapp
```

Two things do not work without a window manager, and both are limitations of the
environment rather than of MyZig:

* A **tray icon** has nowhere to go, so `tray` reports `not shown`.
* WebKit content is **not captured** by an X11 screenshot (it comes out black).
  Page behaviour is verified through the page's own console output instead. A
  native window and its surface do capture correctly.

## Windows

Backend: `src/platform/windows/`. **Written and cross-compiled; never run.**
There is no Windows machine to test on, so nothing below is verified, and this
section says so rather than claiming otherwise.

| Feature | State | Notes |
| --- | --- | --- |
| Windows, resize, close, fullscreen | written, unrun | Win32, per-monitor DPI aware |
| Web pages | written, unrun | WebView2 through COM |
| `myzig://` scheme | **not written** | WebView2 needs a resource filter; pages load from `http` or `file` today |
| Typed IPC | written, unrun | same bridge script as Linux |
| Menu bar | written, unrun | `CreatePopupMenu` + `AppendMenu`, ids via `WM_COMMAND` |
| Tray icon | written, unrun | `Shell_NotifyIcon` on a message-only window |
| Global shortcuts | written, unrun | `RegisterHotKey`, delivered as `WM_HOTKEY` to the message loop |
| Native UI surface | written, unrun | off-screen DIB + `BitBlt`, software rasteriser |
| Desktop APIs | written, unrun | clipboard, file dialogs, message boxes; notifications go to a tray balloon; reveal-in-folder answers `false` |
| Window geometry persistence | written, unrun | shares `utils/instance.zig` and the app's `window-state.json` |
| Single instance | written, unrun | a named mutex, `Local\<name>.lock` |

`WebView2Loader.dll` is opened at runtime, so an application that never opens a
page never needs it. `bcryptprimitives.dll` is linked, because it is the only
entropy source `std.os.windows` still reaches.

The trusted-types CSP trick that lets the Linux bridge use `new Function` does
not exist in WebView2 the same way; the bridge runs there unmodified but that
part of it is untested.

## macOS

Backend: `src/platform/macos/`. **Written, compiles for `aarch64-macos` and
`x86_64-macos`, never run.** There is no Mac on the machine this was written
on, so nothing below has been observed working; the table says what the code
does, not what has been seen.

The backend talks to AppKit and WebKit through the Objective-C runtime, which
is opened by name (`/usr/lib/libobjc.A.dylib`) rather than linked: macOS has no
`dlopen` step for it, and opening it by name means a Linux host can compile
**and link** the backend without a macOS SDK. Every entry point this backend
uses — `objc_msgSend`, `objc_allocateClassPair`, `class_addMethod`,
`objc_setAssociatedObject` and the rest — is looked up that way, so
`zig build -Dtarget=aarch64-macos` produces a real Mach-O binary on a Linux
host. A build *on* a Mac additionally links AppKit, Foundation, WebKit and
CoreGraphics (`build.zig`), which is what a runnable application needs.

Delegates and menu targets are classes built at run time from Zig function
pointers (`delegate.zig`), so the backend still compiles no Objective-C.

| Feature | State |
| --- | --- |
| Window creation, title, frame, show/hide, focus | written |
| Minimise, restore, zoom, always-on-top, full screen | written |
| page and hybrid windows | `WKWebView`, written |
| native windows | written: an `NSView` subclass rasterises the canvas into a `CGImage` |
| native input | written: mouse press/release/drag, wheel, key down/up, committed text |
| native accessibility | written: an `NSAccessibilityElement` tree, published per frame |
| `evalJs` | written: a completion block is passed, so the reply path exists |
| `injectScript` | written: `WKUserScript` in a `WKUserContentController` |
| window menus | written: an `NSMenu` bar on `NSApp`, clicks by tag |
| tray | written: `NSStatusItem` with a one-entry menu |
| close button asks before closing | written: a window delegate reports the request |
| page load finished / failed events | written: a navigation delegate |
| monitors, system theme | written: `NSScreen`, `effectiveAppearance` |
| calling from another thread | written: `dispatch_async_f` to the main queue |
| global shortcuts | written: Carbon `RegisterEventHotKey`, which needs no permission |
| desktop APIs | written: clipboard, dialogs, opening files; `notify` returns `false` |
| window geometry persistence | written: the same `window-state.json` as Linux |
| single instance | written: `flock`, as on Linux |
| `myzig://` scheme | **not written** — a page is loaded from a URL the system can reach |

Global shortcuts are written, through Carbon's `RegisterEventHotKey` rather
than an `NSEvent` monitor: a monitor would ask the user to grant Accessibility
permission, which many people decline, leaving the shortcut silently dead.

The desktop APIs are written: clipboard (`NSPasteboard`), file dialogs
(`NSOpenPanel`/`NSSavePanel`), message boxes (`NSAlert`), opening a URL and
revealing a file (`NSWorkspace`), and the light/dark preference. Notifications
are the one deliberate gap: `NSUserNotificationCenter` needs a bundle
identifier and is deprecated, and `UNUserNotificationCenter` needs an
authorization prompt this backend cannot await, so `notify` returns `false`
rather than posting something macOS would silently drop.

**A caveat about blocks.** `evaluateJavaScript:completionHandler:` needs a
block, which this backend builds by hand from the ABI's layout (`objc.zig`).
The block it passes is a *global* block — it captures nothing — which is the
only kind that is safe to share as static data. Nothing here has been run to
confirm the runtime accepts it.

## What "not supported" looks like

An unsupported feature never silently does nothing. It returns:

* `false` from a `bool`-returning call (`writeClipboard`, `notify`,
  `openExternal`).
* `null` from an optional-returning call (`readClipboard`, `messageBox`).
* `error.NotSupported` from an error-union call (`fileDialog`).

An application can therefore branch on the answer instead of discovering the
gap in the field.

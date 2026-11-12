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
| Global shortcuts | verified | X11 key grab |
| Native UI surface | verified | GTK drawing area, software rasteriser |
| Native UI input | verified | mouse press and release |
| Accessibility | verified | AT-SPI over D-Bus: a reader walks the tree |
| Wayland session | verified | a whole window, drawn and legible, captured with `grim` |
| Global shortcuts | X11 only | Wayland refuses them with `NotSupported`, by design |

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
| Tray icon | **not written** | needs `Shell_NotifyIcon` |
| Global shortcuts | **not written** | needs `RegisterHotKey` |
| Native UI surface | written, unrun | off-screen DIB + `BitBlt`, software rasteriser |
| Desktop APIs | **not written** | clipboard, dialogs, notifications |

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
`dlopen` step for it, and opening it by name means a Linux host can compile the
backend without a macOS SDK. On a Mac the frameworks still have to be linked —
`zig build -Dtarget=aarch64-macos` needs the SDK to find them.

| Feature | State |
| --- | --- |
| Window creation, title, frame, show/hide, focus | written |
| Minimise, restore, zoom, always-on-top, full screen | written |
| page and hybrid windows | `WKWebView`, written |
| native windows | bitmap surface allocated, **no input** |
| `evalJs` | written, but the reply is dropped: no completion block is built |
| `injectScript` | **not written** — needs `WKUserScript` and a content controller |
| window menus | **not written** — needs `NSMenu` |
| tray, global shortcuts, desktop APIs | **not written** |
| `myzig://` scheme | **not written** — a page is loaded from a URL the system can reach |
| monitors, system theme | **not written** — the answers are "none" and "light" |

Two things are absences rather than bugs, and both are marked in the code: a
call from another thread is dropped instead of being run on a background thread
(AppKit is not thread-safe, and hopping to the main queue needs a block), and a
native window's mouse presses are not delivered to the application.

## What "not supported" looks like

An unsupported feature never silently does nothing. It returns:

* `false` from a `bool`-returning call (`writeClipboard`, `notify`,
  `openExternal`).
* `null` from an optional-returning call (`readClipboard`, `messageBox`).
* `error.NotSupported` from an error-union call (`fileDialog`).

An application can therefore branch on the answer instead of discovering the
gap in the field.

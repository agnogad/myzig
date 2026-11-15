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
| 4 | Native UI toolkit: layout, rendering, accessibility | **In progress** (layout, rasteriser, input, AT-SPI and macOS `NSAccessibility` done; Unicode text is Latin-1 only) |
| 5 | Command line: `new`, `generate`, `doctor` | **Done** |
| 6 | Windows backend: Win32 + WebView2 | **Written, compiles for Windows, not yet run** |
| 7 | macOS backend: AppKit + WKWebView | **In progress** (windows, pages, menus, tray, monitors; compiles and links; never run) |
| 8 | Ecosystem: plugins, packaging, auto-update | **In progress** (plugins and `myzig package` done; update checking, fetching and verification done, self-replacement not written) |

Window geometry persistence and single-instance enforcement are now
implemented and tested; they were previously parsed-and-ignored options.

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
* **Single-instance is enforced on Linux, macOS and Windows.** Windows uses a
  named mutex; the other two use `flock`. Nothing is verified on Windows
  because there is no Windows machine here, but the module builds for it.
* **Single-instance requires `AppOptions.io`.** Zig 0.17 routes file access
  through `std.Io`, so an application that passed no handle cannot create its
  lock file and runs unlocked, with a warning.
* **Window state persistence requires `AppOptions.io`** for the same reason, and
  stores one `window-state.json` keyed by `state_key` in the data directory.
  Position is only restored as a pair, and only once the backend has reported a
  real position — otherwise a default `(0, 0)` would move the window to the
  corner on the next start.

## Window geometry and single instance

Two options had been parsed and then ignored: `state_key`, whose save and load
functions were empty stubs, and `single_instance`, which nothing read.

**Geometry** is written to `<data>/window-state.json` as one object keyed by
`state_key`, so several windows with different keys do not overwrite each other.
A save reads the existing file first and replaces only its own key. The write
goes to a temporary name and is renamed into place, so an interrupted write
leaves the previous file intact rather than a half-written one that the next
start would silently discard. A corrupt or unreadable file is treated as "no
saved state" rather than an error: remembering a window is a convenience, and
it must not stop an application from starting.

Saving happens both when a window is destroyed and in `App.deinit` for windows
still open, so quitting with the window up keeps its size.

**Single instance** uses `flock(LOCK_EX | LOCK_NB)` on `<data>/<name>.lock`. The
kernel releases a `flock` when the process exits, including when it is killed,
so a crash cannot lock the application out permanently — which a pid file would
get wrong the moment a pid is reused. The lock is taken in `run`, before the
backend starts, so a second copy never opens a window it would have to take
back.

On Windows the same rule is carried by a named mutex, `Local\<name>.lock`. The
trap there is that **a non-null handle does not mean "another instance"**: a
brand-new mutex also returns a handle. Only `ERROR_ALREADY_EXISTS` read from
`GetLastError` *immediately* after the call says the name was taken, and that
`GetLastError` must be read before anything else can overwrite it. The name is
prefixed `Local\` so two users on one machine each get their own instance, and
an over-long name is refused rather than passed on, because Windows truncates
object names instead of rejecting them and a truncated name would collide with
another application's.

The failure classification is the part worth reading: only `EAGAIN` means
"another copy is running". Every other failure — an unwritable directory, a full
file system — is reported as `unavailable` and the application **runs anyway**.
Treating those as "already running" would make an application exit silently, with
no window and no explanation, because of a permissions problem.

### Two bugs the tests found

1. **A use-after-free in the loader.** `readStateDoc` freed the parse buffer
before returning, while `json.Value` borrows its slices. The parse succeeded and
the fields pointed at released memory, so a saved 900-pixel window came back at
its default 500. It is fixed by leaving the buffer in the caller's arena.
2. **A leak in `Exchange.deinit`.** `app_listeners` was never freed, so any
application that called `App.listen` leaked at exit. It only became visible once
something ran a listener *and* stopped, which the single-instance path does.

Verified by running: `notes` now opens at **777×555** when its state file says so,
not at its requested 640×560; a second `notes` prints
`Notes is already running` and exits before creating a window.

## Update verification

`src/update.zig` is the half of auto-update that can be proved on this machine:
it parses a JSON feed, decides whether a version is newer, and verifies an
ed25519 signature over the feed's `url` and `sha256`.

Three decisions are the substance of it:

* **The signature covers the URL and the digest together**, separated by a
  newline. Covering only the bytes would let an attacker who captured a genuine
  feed point it at a different artifact; covering them with no separator would
  let `url "ab" + digest "cd"` and `url "abcd" + digest ""` sign identically.
* **A downgrade is its own error.** A correctly signed *older* release is the
  rollback attack, and a signature check alone passes it. `isNewer` refuses
  equality too, so re-installing the running version cannot restart the
  application for nothing.
* **The digest is checked after the signature**, not before. A signature over a
  digest that does not match the downloaded bytes verifies the wrong thing.

Tested with a real key pair: a signature made over one URL must fail when the
URL changes, when the digest changes, and when the key changes. Keys come from
`generateDeterministic` with fixed seeds so a failure is reproducible.

## Fetching, over real HTTP

`src/update_fetch.zig` adds the network half and `myzig update-check` exposes it.
The split exists so the test suite needs no network: `update.zig` is pure and
`update_fetch.zig` is the only file that can fail because a socket did.

Downloads are bounded (64 KiB for a feed, 512 MiB for an artifact) so a server
that streams forever is stopped before it fills a disk.

Verified against a local `python3 -m http.server`:

| Sent | Result |
| --- | --- |
| a correctly signed feed | `update available: 2.0.0` |
| the same feed with `url` edited after signing | `BadSigning`, exit 1 |
| a wrong `--key` | `BadSigning`, exit 1 |
| `{not json` | `BadFeed`, exit 1 |
| a feed with no `signature` | `MissingField`, exit 1 |
| a 404 | `BadStatus`, exit 1 |
| an unreachable port | `FetchFailed`, exit 1 |
| a feed older than `--current` | `up to date`, exit 0 |

### A leak the live run found

The first run of `update-check` leaked 312 bytes every time. `json.parse` returns
the parser alongside the value, and the parser owns the arena the fields live in;
`update.parse` dropped it. Two consequences were worth writing down:

* The leak is invisible in a program that exits, which is why it took running the
  command rather than a unit test to see it.
* The fix is a `defer`, and a `defer` there is only safe because `parseOwned`
  copies every field before `parse` returns — otherwise the same change would
  have turned a leak into a use-after-free.

**Nothing installs anything.** The command stops at the decision, and there is no
code on the path that replaces program files.

## The macOS backend, second pass

The macOS backend could be compiled but never linked from this host: it called
`objc_allocateClassPair`, `class_addMethod` and `objc_setAssociatedObject`
directly, and those symbols only exist in a macOS SDK. Every entry point is now
looked up through `std.DynLib`, exactly as the Linux backend treats GTK, so
`zig build -Dtarget=aarch64-macos` produces a real Mach-O arm64 binary on Linux.
A build *on* a Mac still links AppKit, Foundation, WebKit and CoreGraphics,
which `build.zig` now does.

What changed, in the order it matters:

1. **Delegates are Zig.** `platform/macos/delegate.zig` builds the window and
   navigation delegate classes at run time. The close button now produces a
   close *request*, which the application can refuse; a page reports
   `didFinishNavigation` and a failure with the system's own message.
2. **`injectScript` works.** The IPC bridge needs to exist before the page's
   own first script, which is what `WKUserScript` at document start is for. A
   backend without it had no typed IPC at all.
3. **`evalJs` passes a completion block.** The bridge replies over this call, so
   a null handler meant every page call timed out. The block is built from the
   ABI's layout in `objc.zig`, since the backend compiles no Objective-C.
4. **A menu bar.** `platform/macos/menu.zig` builds an `NSMenu` and installs it
   on `NSApp` — on macOS the bar belongs to the application, not a window —
   with About/Hide/Quit added when the application did not supply them, and
   clicks returned by tag.
5. **A tray.** An `NSStatusItem` with a template image and a one-entry menu; a
   status item with no menu is not clickable, which is why the menu is
   mandatory rather than cosmetic.
6. **Monitors and the system theme.** `NSScreen.screens` with the Y axis
   flipped into the framework's top-left convention, and
   `effectiveAppearance` rather than user defaults so an overridden appearance
   is respected.
7. **Cross-thread calls reach the main queue** through `dispatch_async_f`,
   which takes a plain function pointer and so needs no block.

The tray moved into the backend contract (`create_tray` / `destroy_tray`) so
each platform answers for itself; Linux still builds it in `gtray.zig` because
it needs a GTK window, and the testing and Windows backends answer `false`
rather than pretending.

Verified here: 206 unit tests pass (1 skipped), all 12 examples pass `scripts/smoke.sh`
under Xvfb, and both `-Dtarget=aarch64-macos` and
`-Dtarget=x86_64-windows-gnu` build. **None of the macOS code has been run**:
there is no Mac on this machine, and a link is not a window.

`scripts/smoke.sh` now always starts its own Xvfb display instead of reusing
whatever `DISPLAY` the caller has, so running the tests does not open windows on
someone's desktop. Set `SMOKE_USE_SESSION=1` to opt in.

## A native window on macOS

`counter-native` and `native-ui` draw a wheel, a header and three buttons with
no web engine. On macOS that was the last empty space in Milestone 4: the
backend allocated a pixel buffer nobody ever filled, and no mouse press ever
reached the framework.

`platform/macos/surface.zig` closes it the same way Windows does:

1. The application's UI code fills a `ui.canvas.Builder`.
2. `ui.canvas.render` rasterises it into an RGBA buffer the surface owns.
3. `drawRect:` wraps that buffer in a `CGImage` and paints it into the view's
   CoreGraphics context.

The view is a class built at run time (`MyZigBitmapView`), because a press only
arrives at `mouseDown:` and a key only at `keyDown:` — Objective-C methods this
backend registers from Zig function pointers, so still no `.m` file anywhere.
`keyDown:` sends committed text as `text` and the press as `key_down`; a
control character is a command key and is not sent as text.

Three details that are easy to get wrong, and are written down in the code:

* **Coordinates.** AppKit is bottom-left with Y up; MyZig is top-left with Y
  down. Every point is flipped once in `pointInView`, and `flipY` has a test.
* **Modifiers.** Command is `1 << 20` and maps to `Modifiers.super`, which is
  what `primary()` reads on macOS — so Command-click is a primary click without
  a second field.
* **Argument order.** `CGContextDrawImage` takes the rect by *pointer* in the
  order `(context, rect, image)`, unlike the AppKit methods that take structs
  by value. Zig did not catch this: the first version passed them the other way
  and type-checked, because both are `?*anyopaque`. It was found by reading the
  signature rather than by compiling.

CoreGraphics is looked up through `std.DynLib` like everything else here, so
`zig build -Dtarget=aarch64-macos` still links on a Linux host. What is tested
here is the pure part — the Y flip, the modifier mapping and the byte swap — and
nothing else: **no frame has been drawn on a Mac.**

## Accessibility on macOS

A native window is pixels, and pixels say nothing to VoiceOver. The application
already describes its interface with `ui.accessibility.Builder` once per frame,
beside the drawing it describes; Linux publishes that tree over AT-SPI. macOS
now publishes the same tree as `NSAccessibilityElement`s hung under the view.

`platform/macos/a11y.zig` is deliberately two layers:

* **The mapping**, which is pure Zig and tested on the host: MyZig roles to
  `AXButton`/`AXStaticText`/`AXRadioGroup` and the rest, the label fallback
  (name, then value, then description), the frame in *parent space*, and which
  MyZig actions AppKit actually has — `AXPress`, `AXIncrement`,
  `AXDecrement`, and no `AXFocus`, because focusing is navigation rather than
  an action there.
* **The object graph**, which needs the real framework and has never been run.

### A reader can press

An element also needs to *answer* a press. AppKit asks by sending
`accessibilityPerformPress` to the element, and a stock
`NSAccessibilityElement` does not have that method — so VoiceOver could read
every button and then do nothing when asked to activate one.

`MyZigA11yElement` is therefore a class built at run time from
`NSAccessibilityElement`, the same way the window delegates are, with one
added method. Each element records which window and node it stands for, so the
press arrives as `(window_id, node_id)` and runs the ordinary pointer path.

The back-reference map is per element pointer, and two things there needed
care:

* Republishing one window must not forget the *other* windows' elements, so
  only the entries for that window are dropped.
* Collecting the entries to drop uses a real list rather than a fixed buffer: a
  silent cap would leave stale keys pointing at freed elements, which is
  exactly the case where a press would touch memory that is gone.

### Not re-reading for an unchanged frame

Rebuilding the whole tree whenever a window repainted seemed harmless until the
frame rate is taken seriously: a window repainting at 60 Hz would ask VoiceOver
to re-read itself 60 times a second, which makes a reader unusable rather than
slow.

So a publish is skipped when the tree says exactly what the last one said. That
is decided by a 64-bit hash of everything about a node that reaches AppKit —
role, bounds, states, name, description, value, actions and parent — and it has
tests that each of those fields, moved on its own and put back, invalidates and
then restores the hash. Bounds are in it even though a move is silent: it is
where VoiceOver draws its highlight and where a hit test lands.

Two details that are easy to get wrong and are checked rather than assumed:
`Role` and `States` are one byte each with no tag padding, so hashing them by
their bytes compares what actually differs; and each string is followed by its
length, so `"ab"+"c"` and `"a"+"bc"` do not hash alike.

A collision costs one frame of stale accessibility, not a wrong screen, which is
why a hash is enough where a deep comparison would be paid for on every frame.

## Global shortcuts on macOS

`registerShortcut` used to answer `NotSupported` on macOS. It now goes through
Carbon's `RegisterEventHotKey`, which is old, still not deprecated, and — the
reason it is used at all — needs no permission. The obvious alternative,
`NSEvent.addGlobalMonitorForEvents`, works but silently requires the user to
grant Accessibility access; people decline, and the shortcut then does nothing
for no visible reason.

The trap here is not the API but the numbers. Carbon's modifier masks are a
different layout from Cocoa's:

| modifier | Carbon | Cocoa |
|----------|--------|-------|
| Cmd      | `1<<8` | `1<<20` |
| Shift    | `1<<9` | `1<<17` |
| Option   | `1<<11`| `1<<19` |
| Control  | `1<<12`| `1<<18` |

Passing a Cocoa flag into `RegisterEventHotKey` registers the wrong chord and
fails silently. `menu.zig` already uses the Cocoa numbers for menu key
equivalents, so both tables now exist side by side — which is exactly the
condition that lets them be confused. The Carbon one is asserted by value in
tests, not derived.

Key codes have the same flavour of trap: they follow the keyboard, not the
alphabet. `kVK_A` is 0 and `kVK_S` is 1, the digits run across the number row
instead of in order, and the key a Mac keyboard labels *Delete* is BackSpace
(0x33) while forward delete is 0x75. A first draft mapped both to 0x33 — which
would have bound the wrong key, silently — and a test now separates them.

Anything Carbon has no code for — `unknown` — is refused rather than given a
made-up number.

## The macOS desktop APIs

The last large hole in the macOS backend was the desktop contract: clipboard,
dialogs, notifications, opening things outside the app, and the light/dark
preference. Most of it is a thin layer over AppKit, but three details are the
kind that compile happily and then behave wrongly, so each is a pure function
with a test:

* **`NSModalResponseOK` is 1 and cancel is 0.** A swapped comparison turns a
  cancel into a choice.
* **The first `NSAlert` button answers 1000, not 0.** Without the subtraction
  every answer looks like the first button.
* **`NSAppearance` names carry their family**, so the high-contrast variants are
  dark exactly when their name contains `Dark`.

A fourth is about refusing rather than guessing: the contract's filter is
glob-ish (`*.png`) while `NSOpenPanel` wants a literal extension (`png`). This
version refuses a wildcard *inside* the extension (`*.p*g`) instead of passing
it through, because AppKit would then show an empty file list with no
explanation. The first draft of this test failed exactly there, which is why the
rule is written down.

**Notifications are the one deliberate gap.** `NSUserNotificationCenter` needs a
bundle identifier and is deprecated; `UNUserNotificationCenter` needs a user
authorization prompt that this backend has no way to show, let alone await.
`notify` returns `false` rather than posting something macOS would silently
drop, which is the rule the whole file follows.

Nothing here has been run either: there is no Mac. The mappings are tested; the
AppKit calls are not.

## A COM vtable that was quietly calling the wrong methods

Going to add `myzig://` support on Windows meant reaching
`AddWebResourceRequestedFilter`, which meant reading `ICoreWebView2`'s vtable —
and that turned up a bug worse than the missing feature.

**A COM call is a slot index.** The struct in `webview2.zig` listed the methods
this backend used and skipped seventeen it did not, between `ExecuteScript` and
`OpenDevToolsWindow`. So `ExecuteScript` was fine by luck of position, but
`OpenDevToolsWindow` — the field after the gap — actually reached slot 30,
which is `CapturePreview`. `open_devtools` on Windows would have captured a
bitmap and thrown it away. Nothing failed, because COM calls do not fail when
you name the wrong method; they call it.

The struct now follows the documented IDL order, with every unnamed method
still occupying its slot, and a compile-time assertion that the field count is
61:

```zig
comptime {
    if (@typeInfo(@This()).@"struct".field_names.len != slot_count) {
        @compileError("CoreWebView2Vtbl out of step with ICoreWebView2: " ++
            "every method must occupy its documented slot");
    }
}
```

That assertion is the part that matters. It is the check that would have
caught the original bug, and it means a method can no longer be added *in the
middle* of the interface without the build failing.

The offsets were then read back rather than assumed: `ExecuteScript` 29,
`OpenDevToolsWindow` 51, `add_WebResourceRequested` 55,
`AddWebResourceRequestedFilter` 57 — matching the published
`ICoreWebView2Vtbl`. `myzig://` itself is now unblocked rather than blocked by
a wrong filter slot.

Nothing about this is verified at run time; it is still a Windows backend that
has never started. But the misalignment is fixed, and the next one is a
compile error.

## Global shortcuts on Windows

`RegisterHotKey` binds a chord system-wide with no hook and no elevated
permission, and posts `WM_HOTKEY` with the binding's id in `wparam`.

Three things needed care:

* **`MOD_*` masks are their own convention.** `MOD_ALT` is 1, `MOD_CONTROL` is
  2, `MOD_SHIFT` is 4 and `MOD_WIN` is 8. The macOS backend uses 1<<11, 1<<12,
  1<<9 and 1<<8 for the same four keys, so a table copied between them is wrong
  in every row. Both are asserted by value, in separate files, with a comment
  saying why the other exists.
* **A collision comes back through `GetLastError`, not the return value.**
  `RegisterHotKey` answers 0 for "already taken" (error 1409) and for every
  other failure alike. Reporting "already taken" for an unrelated error would
  send a caller hunting for another application that is not there.
* **`WM_HOTKEY` for a thread-level binding never reaches a window procedure.**
  It is posted to the queue, so it is handled in the message loop before
  `DispatchMessageW` — otherwise it is dropped as an unknown message with
  nothing to see.

A shortcut with no modifier is refused: Windows will not bind a bare key
globally, and a global bare key would swallow that key everywhere.

Bindings are released in `deinit`. Windows keeps a chord claimed after the
process exits otherwise, so a second run of the same application would find its
own shortcuts "already taken".

## A tray icon on Windows

`create_tray` answered `false` on Windows, so an application that wanted a
notification-area icon got a window instead. It now uses `Shell_NotifyIcon`
against a **message-only window** (`HWND_MESSAGE`, a `-3` parent): a window that
exists purely to receive the tray's callbacks and never appears.

Two details that are easy to get wrong:

* **Which message means "clicked" depends on the notification version.**
  Version 4 sends `NIN_SELECT` and `WM_CONTEXTMENU`; older versions send
  `WM_LBUTTONUP` and `WM_RBUTTONUP`. All four are mapped, because whether
  `NIM_SETVERSION` was honoured cannot be checked. A test asserts both pairs
  reach the same two items — answering one pair would make the icon work on some
  Windows versions and not others, with nothing to see.
* **`NOTIFYICONDATAW` has two names for one field.** `uTimeoutOrVersion` is a
  union: a timeout before version 4, the version marker after it. Setting it is
  how the newer layout is requested.

The tray also gave notifications a real implementation: the same
`NOTIFYICONDATAW` carries a balloon, so `notify` sets `NIF_INFO` and modifies
the existing icon rather than trying to post a toast the system would drop.

## The Windows desktop APIs

Windows had no desktop contract at all: `clipboard`, dialogs, notifications,
`openExternal` and the theme all fell through to the inert table. Most of it is
now written against `user32`, `comdlg32` and `shell32`.

Three Win32 details fail silently and are therefore pure functions with tests:

* **`lStructSize` must be `@sizeOf(OPENFILENAMEW)`.** Get it wrong and the call
  returns zero with no error to read — indistinguishable from a cancel.
* **The filter is a double-NUL-terminated list** of label/value pairs followed
  by a second NUL, not one string.
* **A multi-select dialog returns `dir\0file1\0file2\0\0`**, not a path per
  line. Read as text it is one nonsense path; the splitter turns it into N real
  ones, and a directory that already ends in a separator is not doubled.

The message box has the same shape of trap: `IDOK` is 1, `IDYES` is 6 and
`IDNO` is 7, so the answer index is a mapping rather than the return value.

**Notifications** go to a tray balloon. A Windows 10 toast needs a registered
AppUserModelID and a Start-menu shortcut, and without them the system drops it
silently; the balloon needs neither and is what actually appears. With no tray
shown there is nowhere to put it, and that returns `false` rather than
swallowing the message.

**Reveal in folder** needs an `IShellItem` from `SHParseDisplayName`, which is
COM this backend has not built, and opening the folder without selecting the
file would be a half-answer. The theme reads `.light` for the same reason: the
registry value needs `advapi32`, which is not linked, and an application that
cannot read it must not claim the user asked for dark.

### A crash the tests found

Adding the Windows desktop module pulled `ffi.utf16` into the test run, where it
**aborted** rather than returning null:

```
panic: index out of bounds: index 1, len 1
  std/unicode.zig: utf8ToUtf16LeImpl
  src/platform/windows/ffi.zig: utf16
```

`std.unicode.utf8ToUtf16Le` documents that it *"assumes there is enough
space"* and writes past the end of a short slice instead of returning an error,
so the helper's `catch return null` could never fire. Its own test had been
asserting `null` and passing only because nothing ran it. The buffer is now
measured first, with a test for the case a byte count gets wrong: a rune outside
the BMP is four UTF-8 bytes but **two** UTF-16 units, so counting bytes
overestimates and counting codepoints underestimates by one.

Two rules the tree keeps, both with tests:

* A **hidden** node gets no element, and its *children* hang off the nearest
  visible ancestor instead, so hiding a group never makes a button unreachable.
* A press from a reader goes through the same down-then-up pair a real click
  produces (`pressAt`), at the node's centre, so the application's own handler
  runs. There is no second code path that could drift from the mouse.

The frame conversion is the part most likely to be wrong in a way that still
compiles: `accessibilityFrameInParentSpace` is bottom-left with Y up in points,
MyZig is top-left with Y down, and the flip is applied exactly once against the
container's height. That flip has a test.

Nothing here has been seen working, and `docs/platforms.md` says so.

## Next

1. **Auto-update** (Milestone 8): feed format, version comparison, ed25519
   signature check, artifact digest, HTTP fetching and `myzig update-check` are
   written and tested. What is missing is the swap-and-restart, which needs a
   real installation to test. See `docs/packaging.md`.
2. **Single-instance on Windows** is now written; what remains is running it on
   a Windows machine, which this project has never had.
3. **Unicode text in the native UI toolkit** (Milestone 4): the bitmap font
   covers ASCII 32–126 only, so a native window cannot draw more than Latin-1.
4. **Run the Windows and macOS backends.** Both compile and link; neither has
   ever been started on its own host. Until someone runs `notes` on a Windows
   machine and on a Mac, every claim about those backends is a claim about code
   that type-checks.

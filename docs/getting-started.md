# Getting started

This walks through a working application from an empty directory. It takes about
two minutes and ends with a window you can click.

## 1. Install

```sh
git clone https://github.com/your-org/myzig
cd myzig
zig build install
export MYZIG_HOME=$PWD
export PATH=$PWD/zig-out/bin:$PATH
```

`myzig doctor` should now report your Zig version and the native libraries it
found:

```sh
myzig doctor
```

If a library is missing, install it before continuing. On Arch:

```sh
sudo pacman -S gtk3 webkit2gtk-4.1 cairo libx11
```

## 2. Create a project

```sh
myzig new hello
cd hello
zig build run
```

A 720×460 window appears with a heading and a button. The button calls Zig and
shows the answer.

## 3. What was generated

```
hello/
  build.zig
  build.zig.zon          # depends on the framework checkout
  src/
    main.zig             # the application
    index.html           # the page
    app.js               # the page's script
```

`src/main.zig`:

```zig
const std = @import("std");
const myzig = @import("myzig");

/// The page's frontend, embedded in the binary so the executable is the whole
/// application. Nothing is read from disk at runtime.
const frontend = [_]myzig.FrontendFile{
    .{ .path = "index.html", .mime = "text/html; charset=utf-8", .data = @embedFile("index.html") },
    .{ .path = "app.js", .mime = "text/javascript", .data = @embedFile("app.js") },
};

/// The reply buffer must outlive the handler, so it cannot be a local.
var reply_buf: [128]u8 = undefined;

fn greet(_: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    var a = args;
    const name = a.stringBounded(64) catch |e| return myzig.ipc.Args.toResult(e);

    const text = std.fmt.bufPrint(&reply_buf, "Hello, {s}!", .{name}) catch
        return myzig.ipc.Result.fail(.internal, "reply too large");
    return myzig.ipc.Result.success(.{ .string = text });
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();

    var app = try myzig.App.init(gpa_state.allocator(), .{
        .name = "Hello",
        .app_id = "dev.myzig.hello",
        .frontend = &frontend,
    });
    defer app.deinit();

    try app.bind(.{ .name = "Hello.greet", .invoke = greet, .arity = 1 });

    _ = try app.createWindow(.{
        .title = "Hello",
        .width = 720,
        .height = 460,
        .url = "myzig://app/index.html",
    });

    try app.run();
}
```

Three things to notice:

* **`App.init` copies the strings it is given** into its arena, so a stack
  buffer is fine.
* **The reply buffer is module-level.** A reply is encoded after the handler
  returns; a pointer to a local would be a use-after-free.
* **`arity = 1`** is checked against the call, so a page that sends the wrong
  number of arguments gets `invalid-argument` rather than a crash.

`src/app.js`:

```js
window.myzig.on("myzig:ready", async () => {
  const answer = await window.myzig.call("Hello.greet", "world");
  document.getElementById("out").textContent = answer;
});
```

## 4. A native window instead

```sh
myzig new clock --native
cd clock
zig build run
```

No webview is created and no web engine is loaded. The window is drawn by
MyZig's own rasteriser. See [native-ui.md](native-ui.md).

## 5. Next

* [ipc.md](ipc.md) — events, error codes, the generated TypeScript client.
* [native-ui.md](native-ui.md) — the native toolkit.
* [plugins.md](plugins.md) — packaging services.
* [memory-management.md](memory-management.md) — who owns what.

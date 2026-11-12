# Plugins

A plugin is a struct with a name, a setup function and an optional shutdown
function. It exists so that a set of services, hooks and background work can be
packaged and added to an application with one call.

```zig
const ticker = struct {
    pub fn setup(ctx: *myzig.plugins.Context) !void { ... }
    pub fn shutdown(ctx: *myzig.plugins.Context) void { ... }
};

try app.addPlugin(.{
    .name = "ticker",
    .setup = ticker.setup,
    .shutdown = ticker.shutdown,
});
```

## When setup runs

`addPlugin` only records the plugin. Setup runs inside `App.run`:

1. the backend initialises;
2. **plugins start, in registration order**;
3. the first window is created;
4. the event loop runs.

So a service a plugin binds is available to the very first page, with no
handshake. A plugin added after `run` has started is rejected with
`error.AlreadyRunning`: binding a method a page has already looked for and found
missing cannot be undone.

## What a plugin gets

```zig
pub const Context = struct {
    arena: std.mem.Allocator,            // lives as long as the app
    registry: *myzig.ipc.service.Registry,
    desktop: myzig.desktop.Desktop,      // clipboard, dialogs, notifications
    app_name: []const u8,
    app_version: []const u8,

    pub fn bind(self: *Context, method: myzig.ipc.service.Method) !void;
    pub fn bindAll(self: *Context, methods: []const myzig.ipc.service.Method) !void;
};
```

The context is stored, not borrowed: a plugin may keep a pointer to its own
context across calls, which is how a shutdown hook finds what setup created.

## Failure

If a plugin's setup fails, the application does not start. The plugins that had
already started are shut down in reverse order, so a failed start leaves nothing
running:

```
plugin 'alpha' ready
plugin 'beta' failed to set up: SetupFailed
plugin 'alpha' stopping
```

`startAll` returns the failing plugin's error, and `App.run` returns it too.

## Shutdown

`stopAll` runs shutdown hooks **newest first**, and marks each plugin stopped so
a second call does nothing. A hook that joins a thread or closes a file is not
idempotent, so it must run exactly once.

`App.deinit` calls it if `run` did not.

## Rules

A plugin may:

* bind IPC methods, which then appear in the generated TypeScript client;
* read and write the clipboard, show dialogs and notifications;
* start threads, which it must stop in its shutdown hook.

A plugin may **not**:

* create windows — window lifetime belongs to the application;
* block in `setup` — it runs on the main thread, so the first window waits for
  it.

## A complete example

`examples/plugins/main.zig` owns a counter and a thread that increments it every
200 ms and emits an event:

```zig
fn setup(ctx: *myzig.plugins.Context) !void {
    try ctx.bind(.{ .name = "Ticker.count", .invoke = read, .arity = 0, .ctx = &ticker });
    ticker.running.store(true, .release);
    ticker.thread = try std.Thread.spawn(.{}, Ticker.loop, .{&ticker});
}

fn shutdown(_: *myzig.plugins.Context) void {
    ticker.running.store(false, .release);
    if (ticker.thread) |t| t.join();
}
```

The page reads the count and listens for the event:

```js
window.myzig.on("ticker", (value) => { count.textContent = value; });
const now = await window.myzig.call("Ticker.count");
```

Verified in a real window: `Ticker.count` answered `7` and the page received 69
events from the plugin's own thread.

## Limits

`max_plugins` is 32. The registry is a fixed array, so adding a plugin allocates
nothing beyond the plugin list itself.

# Memory management

MyZig has no garbage collector. Every allocation comes from the allocator
handed to `myzig.App.init`, and every value that allocates says who frees it.

## The two allocators in an application

```zig
var gpa_state = std.heap.DebugAllocator(.{}){};
defer _ = gpa_state.deinit();
const gpa = gpa_state.allocator();

var app = try myzig.App.init(gpa, .{ .name = "Hello" });
defer app.deinit();
```

`App.init` keeps three things:

| Field | Lifetime | Used for |
| --- | --- | --- |
| `arena` | until `app.deinit` | strings and frontend files copied from `AppOptions` |
| `scratch` | reset between messages and frames | per-call decoding |
| `gpa` | the application's whole life | the window registry, the service registry, the IPC queues |

An application never frees from `app.arena`. It is released whole, in
`App.deinit`.

## What you own

### Strings passed to `App.init`

`AppOptions.name`, `.app_id`, `.version` and every `FrontendFile` field are
**copied** into the arena. A caller may pass a stack buffer that dies
immediately:

```zig
var buf: [64]u8 = undefined;
const name = try std.fmt.bufPrint(&buf, "My App {d}", .{version});
var app = try myzig.App.init(gpa, .{ .name = name });
```

### Strings passed to `bind`

`ipc.service.Method.name` is **borrowed**, not copied. It must outlive the app.
A string literal is the normal choice; a runtime-built name must be stored
somewhere that lasts as long as the application.

### Replies

A handler returns `myzig.ipc.Result`. The `json.Value` inside it **must
outlive the handler**: the reply is encoded after the handler returns, so a
value pointing at a local buffer is a use-after-free.

Two correct patterns:

```zig
// 1. A module-level buffer, for one handler at a time.
var reply_buf: [128]u8 = undefined;

fn greet(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const text = std.fmt.bufPrint(&reply_buf, "hello", .{}) catch
        return myzig.ipc.Result.fail(.internal, "reply too large");
    return myzig.ipc.Result.success(.{ .string = text });
}
```

```zig
// 2. A raw reply, which the framework copies synchronously.
return myzig.ipc.Result.successRaw("hello");
```

Pattern 1 is safe **only** when handlers do not run concurrently. They run one
at a time per process, on the main thread, so it is safe — but a reply built
from `state` fields is clearer when the state is shared.

### Buffers you hand to desktop APIs

```zig
var buf: [4096]u8 = undefined;
if (app.readClipboard(&buf)) |text| {
    // `text` borrows `buf`; it is invalid once `buf` is reused.
}
```

The same rule holds for `FileDialogOptions` path output: the returned slices
borrow the `PathBuffer` the caller supplied.

### Values the framework returns

| Call | Owner |
| --- | --- |
| `app.createWindow` | the `Window` handle is a value; nothing to free |
| `app.windowById` | borrows app state |
| `app.pluginNames` | borrows app state; valid until `app.deinit` |
| `myzig.webview.script` | **the caller** |
| `app.emit` | nothing; the payload is encoded immediately |

## What the framework frees

`App.deinit` destroys every window, releases the plugin registry, the IPC
exchange, the path set, the scratch allocator and the arena — in that order, so
nothing points at memory that is already gone. It is safe to call without
`App.run`.

`myzig.plugins.Registry.stopAll` runs shutdown hooks newest first and marks each
plugin stopped, so a second call does nothing. A plugin that starts a thread
must join it there; the framework cannot know about it.

## Finding a leak

`std.heap.DebugAllocator` checks on `deinit`. The test suite runs every test
under it, so a leak in the framework or in the examples' patterns fails the
build:

```sh
zig build test --summary all
```

For an application, keep the `DebugAllocator` in `main` as the examples do. A
leak prints the allocation's stack trace at exit.

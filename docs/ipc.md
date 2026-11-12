# IPC

A page calls Zig with `window.myzig.call`, and Zig calls the page with
`window.myzig.emit`. Both directions carry JSON; the bridge is injected before
any page script runs.

## Binding a service

```zig
try app.bind(.{
    .name = "Counter.add",     // exactly what the page calls
    .invoke = add,             // fn (?*anyopaque, Args) Result
    .ctx = &state,             // any pointer the handler needs
    .arity = 2,                // argument count, checked before the call
});
```

| Field | Meaning |
| --- | --- |
| `name` | `"Service.method"`. Borrowed, not copied: it must outlive the app. |
| `invoke` | The handler. Runs on the main thread. |
| `ctx` | Passed through untouched. Null when the handler needs no state. |
| `arity` | How many arguments the page must send. A mismatch is rejected. |
| `docs` | Optional; appears in the generated TypeScript. |

Handlers run **one at a time, on the main thread**, inside the native event
loop. That means a handler may touch windows directly, and that a long handler
blocks the UI. Work that takes time belongs on the handler's own thread.

## Decoding arguments

`Args` decodes with explicit rules; a wrong type or a missing argument becomes an
error the page can display, never a crash.

```zig
fn add(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    var a = args;
    const x = a.int(i64, .{}) catch |e| return myzig.ipc.Args.toResult(e);
    const y = a.int(i64, .{}) catch |e| return myzig.ipc.Args.toResult(e);
    ...
}
```

| Method | Returns |
| --- | --- |
| `string()` | `[]const u8` |
| `stringBounded(max)` | `[]const u8`, rejecting longer input |
| `int(T, .{})` | integer of type `T` |
| `intOf(T)` | integer, no bounds options |
| `float(T, .{})` | floating point |
| `boolean()` | `bool` |
| `optionalBool()` | `?bool` |
| `enumeration(T)` | an enum tag by name |
| `stringArray(out)` | slices borrowing `out` |
| `object()` | a JSON object's fields |
| `raw()` | the value untouched |
| `windowId()` | which window made the call |
| `done()` | errors when arguments are left over |

## Replying

```zig
return myzig.ipc.Result.success(.{ .string = "hello" });
return myzig.ipc.Result.success(.{ .number = "42" });
return myzig.ipc.Result.successRaw("{\"any\":\"json\"}");
return myzig.ipc.Result.fail(.invalid_argument, "name is empty");
```

**The value inside `success` must outlive the handler.** The reply is encoded
after the handler returns. Use a module-level buffer, a field on the state, or a
string literal. `successRaw` takes text and copies it, so a local buffer is fine
there.

`fail` takes a `Code`, which reaches the page as a stable string:

| Code | String |
| --- | --- |
| `.invalid_argument` | `"invalid-argument"` |
| `.not_found` | `"not-found"` |
| `.not_supported` | `"not-supported"` |
| `.permission_denied` | `"permission-denied"` |
| `.cancelled` | `"cancelled"` |
| `.internal` | `"internal"` |

A rejected call arrives in the page as a rejected promise:

```js
try {
  await window.myzig.call("Counter.add", "one", 2);
} catch (err) {
  console.error(err.code, err.message);   // "invalid-argument", "argument 0 is not a number"
}
```

## Events

Zig to the page:

```zig
_ = app.emit("ticker", .{ .string = "7" });
```

```js
const stop = window.myzig.on("ticker", (value) => {
  console.log(value);
});
stop();   // unsubscribe
```

`emit` returns how many windows were addressed. It is safe to call from any
thread: the payload is queued to the main thread and delivered there.

Page to Zig:

```js
window.myzig.emit("ui:clicked", { id: 3 });
```

```zig
fn onUiClicked(state: *State, window: u32, payload: myzig.json.Value) void {
    const id = payload.get("id") orelse return;
    ...
}

try app.onPageEvent(State, "ui:clicked", &state, onUiClicked);
```

The payload **borrows the inbound message**, so it is valid only during the
handler: copy what you need. `window.myzig.emit` also dispatches to the page's
own listeners, so the same name can be used in both directions.

## The TypeScript client

```sh
myzig generate --out src/api.d.ts
```

Inside a project the generator reads the application's own registry, so the
declaration lists exactly the methods the app binds. Outside a project it writes
the built-in surface.

The output declares:

* `MyZigApi` — one entry per registered service and method.
* `MyZigClient` — `window.myzig`, with `call`, `on`, `off`, `emit`, `windowId`,
  `version`, `clipboard`, `dialog`, `notify`, `window`.

Argument and return types are `unknown`, because a Zig function pointer does not
carry parameter types. Narrow them in an overlay file:

```ts
// src/api.types.ts
import type { MyZigClient } from "./api";

export interface Typed extends MyZigClient {
  call(method: "Counter.add", x: number, y: number): Promise<number>;
}
```

The generated file passes `tsc --strict --noEmit`.

## Built-in services

These exist without the application binding anything:

| Service | Method |
| --- | --- |
| `Clipboard` | `readText`, `writeText` |
| `Dialog` | `open`, `save`, `message` |
| `Notify` | `show` |
| `Shell` | `openExternal`, `showInFolder` |
| `Window` | `setTitle`, `setSize`, `setPosition`, `close`, `state`, `bounds`, `openDevtools`, `setAlwaysOnTop` |

## Security

The bridge carries a per-process secret that every inbound message must present,
so a page open in an unrelated browser cannot post to the framework's message
handler. The bridge is injected into the **top frame only**, so an iframe of
another origin cannot reach it.

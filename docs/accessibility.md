# Accessibility

A native MyZig window is a pixel buffer. That is enough for a sighted user and
nothing at all for a screen reader, which sees a rectangle with no structure in
it. This file describes the structure.

## Describing a window

A window has an `a11y` callback beside its `native_draw` callback. `draw`
produces the drawing list; `describe` produces the tree a reader walks.

```zig
const myzig = @import("myzig");
const ui = myzig.ui;

fn describe(ctx: *anyopaque, builder: *anyopaque, size: myzig.platform.backend.DrawRect) void {
    const state: *State = @ptrCast(@alignCast(ctx));
    const b: *ui.a11y.Builder = @ptrCast(@alignCast(builder));

    // Node 0 is the window itself, already created by `begin`.
    b.setName(0, "Notes") catch return;
    b.setDescription(0, "A notes application.") catch return;

    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Clicks: {d}", .{state.clicks}) catch "Clicks";
    _ = b.leaf(.label, .{ .x = 16, .y = 72, .width = 240, .height = 16 }, line) catch return;

    for (labels, 0..) |label, i| {
        const id = b.beginNode(.button, frames[i]) catch return;
        b.setName(id, label) catch return;
        b.endNode();
    }
}

_ = try app.createWindow(.{
    .title = "Notes",
    .width = 720,
    .height = 380,
    .view = view,
    .native_draw = .{ .func = draw, .ctx = state },
    .a11y = .{ .func = describe, .ctx = state },
});
```

`describe` runs once per frame, immediately before `draw`. The tree therefore
always matches what is on screen: a node that is not drawn is not described, and
a button's frame is the frame it was drawn at.

## Roles

| Role | What a reader says |
| --- | --- |
| `.window` | frame |
| `.button` | push button |
| `.toggle` | toggle button |
| `.checkbox` | check box |
| `.radio` | radio button |
| `.radio_group` | radio group |
| `.label` | label |
| `.text_field` | entry |
| `.list` | list |
| `.list_item` | list item |
| `.group` | panel (structure only) |
| `.slider` | slider |
| `.progress` | progress bar |
| `.heading` | heading |
| `.separator` | separator |
| `.image` | image |

## States

```zig
b.setStates(id, .{ .enabled = true, .focused = true, .checked = false });
```

| Field | Meaning |
| --- | --- |
| `enabled` | can be pressed or typed into |
| `focused` | the user is looking at it |
| `checked` | value of a toggle, checkbox or radio |
| `selected` | the chosen list item or radio |
| `readonly` | readable, not changeable |
| `hidden` | takes space but is not shown |
| `offscreen` | not reachable by navigation |
| `busy` | a region whose changes a reader may defer |

## Nesting

`beginNode` leaves the node open, so the next node added is its child.
`endNode` closes it. A node without children can be added with `leaf`, which
opens and closes in one call.

```zig
const list = try b.beginNode(.list, .{ .x = 0, .y = 0, .width = 400, .height = 200 });
_ = try b.leaf(.list_item, .{ .x = 0, .y = 0, .width = 400, .height = 40 }, "First");
_ = try b.leaf(.list_item, .{ .x = 0, .y = 40, .width = 400, .height = 40 }, "Second");
b.endNode();
```

The builder fills `index_in_parent` and `sibling_count` as children are added,
which is what produces "second of two".

## Strings are copied

`setName`, `setDescription` and `setValue` copy their argument. The builder frees
every string at the next `begin`, so a caller can pass a stack buffer — as the
example above does with `bufPrint`.

## On Linux

The tree is published to AT-SPI over D-Bus. The application owns one session-bus
connection and answers from the thread that pumps the loop, so no reader ever
blocks the UI.

Objects and paths:

```text
/org/a11y/atspi/accessible/root        the application
/org/a11y/atspi/accessible/root/w0     the window in slot 0
/org/a11y/atspi/accessible/root/w0/n3  node 3 of that window's tree
```

The bridge starts on the first frame that has a `describe` callback. A machine
with no accessibility bus is not an error: nothing is published, one debug line
is written, and the application runs normally.

`libdbus-1.so.3` is loaded at runtime, so an application that never publishes a
tree never maps it.

Implemented calls: `GetChildCount`, `GetChildAtIndex`, `GetChildren`, `GetRole`,
`GetRoleName`, `GetName`, `GetDescription`, `GetState`, `GetParent`,
`GetInterfaces`, `GetActions`, `GetActionName`, `DoAction`, `GetText`,
`GetCharacterCount`, `GetCurrentValue`, `GetMinimumValue`, `GetMaximumValue`,
`GetMinimumIncrement`, `GetValueText`, `Contains`, `GetExtents`.

The interface list is per node: `Action` only appears on something a reader can
press, `Text` only where there is text, and `Value` only where there is a
number. A reader believes the list, so naming an interface that answers nothing
would be worse than leaving it out.

**Not implemented:** editing. A reader can read a text field and a slider's
value, but `SetTextContents` and `SetCurrentValue` are not answered, so a reader
can inspect a value without being able to change it.

## Letting a reader press a button

```zig
const id = try b.beginNode(.button, frames[i]);
try b.setName(id, "+10");
try b.setPressAction(id, "+10");
b.endNode();
```

`setPressAction` publishes an action named `"+10"`. When a reader invokes it,
the press is delivered as an ordinary click at the node's centre — the same
down-then-up pair a pointer produces, through the same handler. Nothing in the
application has to know the press came from a screen reader, and a button that
works with a mouse works with a reader.

A node with no actions is readable but not operable, which is the right default
for a label.

## A value a reader can compare

```zig
const slider = try b.beginNode(.slider, .{ .x = 16, .y = 220, .width = 240, .height = 20 });
try b.setName(slider, "Opacity");
try b.setValue(slider, "60%");
b.setNumber(slider, .{ .value = 60, .min = 0, .max = 100, .step = 5 });
b.endNode();
```

`setValue` is the text a reader speaks (`"60%"`); `setNumber` is what it
compares. A reader announces position from the number and its range, because a
string cannot tell it whether the slider is near the top. Both are published, so
the spoken value and the range agree.

## Verifying it

With an application running, another process can read the tree:

```sh
python3 - <<'PY'
import dbus, sys
bus = dbus.SessionBus()
name = sys.argv[1]
root = dbus.Interface(
    bus.get_object(name, "/org/a11y/atspi/accessible/root", introspect=False),
    "org.a11y.atspi.Accessible")
print("children:", root.GetChildCount())
for _, path in root.GetChildren():
    win = dbus.Interface(bus.get_object(name, path, introspect=False),
                         "org.a11y.atspi.Accessible")
    print(win.GetRoleName(), repr(win.GetName()))
    for _, child in win.GetChildren():
        c = dbus.Interface(bus.get_object(name, child, introspect=False),
                           "org.a11y.atspi.Accessible")
        print("  ", c.GetRoleName(), repr(c.GetName()))
PY :1.1234
```

The bus name is in the application's log with `MYZIG_LOG=debug`:

```text
[myzig] debug: accessibility: publishing on ':1.1234'
```

## On Windows and macOS

Neither backend publishes a tree yet. `ui.a11y` itself is platform independent
and its tests run everywhere; what is missing is the platform half — UI
Automation on Windows, `NSAccessibility` on macOS. Until those exist a MyZig
window on either system is opaque to a screen reader, and `docs/platforms.md`
says so.

//! The IPC exchange: page messages in, replies and events out.
//!
//! One `Exchange` owns the service registry and the per-window subscription
//! state. It is the only thing the platform backends talk to, so a backend
//! never sees a service, a method name or an event.
//!
//! ## Flow
//!
//! ```text
//! bridge.js --postMessage--> native handler
//!                             |
//!                             v
//!                     App.handleWebMessage(window, text)
//!                             |
//!                             v
//!                     Exchange.deliver(window, text)   <- parses the batch
//!                             |                             routes each call
//!                             v
//!                     reply batch: [{t:"ok"|"err"}...]
//!                             |
//!                             v
//!                       backend eval_js(window, __myzig.receive(<batch>))
//! ```
//!
//! ## Events
//!
//! `Exchange.emit` collects every window subscribed to an event name and gives
//! the caller one JSON array per window. The framework decides when to flush;
//! events emitted within one turn therefore cost one crossing per window, not
//! one per event.
//!
//! ## Cancellation
//!
//! A call that is still running when the page cancels it cannot be interrupted:
//! a handler is ordinary Zig code. `cancel` is therefore *recorded*, and the
//! reply is dropped when the handler returns, which is the observable part of
//! cancelling. A handler that wants to stop early asks
//! `Exchange.isCancelled(window, id)`.

const std = @import("std");
const json = @import("../json.zig");
const protocol = @import("protocol.zig");
const decode = @import("decode.zig");
const service = @import("service.zig");
const log = @import("../log.zig");

/// Where the exchange sends its output.
pub const Sink = struct {
    ctx: ?*anyopaque,
    /// Runs `code` in the window's page. Returning false means the window is
    /// gone, and the exchange stops tracking subscriptions for it.
    eval: *const fn (ctx: ?*anyopaque, window: u32, code: []const u8) bool,
};

pub const Exchange = struct {
    allocator: std.mem.Allocator,
    registry: service.Registry,
    sink: ?Sink = null,

    /// Per-window subscription names. A window that closes takes its set with
    /// it, so an event never names a window that is gone.
    subscriptions: std.AutoHashMapUnmanaged(u32, SubSet) = .empty,

    /// Per-window cancelled request ids. Bounded: a page that cancels a great
    /// many ids cannot grow this without bound.
    cancelled: std.AutoHashMapUnmanaged(CancelKey, void) = .empty,

    /// Listeners for events the page sends with `window.myzig.emit`, in
    /// registration order.
    page_listeners: std.ArrayListUnmanaged(PageListener) = .empty,
    /// Listeners the application registered for events it emits itself. A menu
    /// click is an application event with no page involved, so an application
    /// that reacts to its own menu needs somewhere to hear it.
    app_listeners: std.ArrayListUnmanaged(PageListener) = .empty,

    pub const PageListener = struct {
        name: []const u8,
        callback: *const fn (ctx: ?*anyopaque, window: u32, payload: json.Value) void,
        ctx: ?*anyopaque,
    };

    /// Listens for an event the page sends with `window.myzig.emit`. The name
    /// borrows the caller's slice, so it must outlive the exchange.
    ///
    /// Returns a registration id that `removePageListener` accepts.
    pub fn addPageListener(
        self: *Exchange,
        name: []const u8,
        callback: *const fn (ctx: ?*anyopaque, window: u32, payload: json.Value) void,
        ctx: ?*anyopaque,
    ) !usize {
        try self.page_listeners.append(self.allocator, .{
            .name = name,
            .callback = callback,
            .ctx = ctx,
        });
        return self.page_listeners.items.len - 1;
    }

    /// Listens for an event emitted with `App.emit`, whatever caused it. The
    /// name borrows the caller's slice and must outlive the exchange.
    pub fn addAppListener(
        self: *Exchange,
        name: []const u8,
        callback: *const fn (ctx: ?*anyopaque, window: u32, payload: json.Value) void,
        ctx: ?*anyopaque,
    ) !usize {
        try self.app_listeners.append(self.allocator, .{
            .name = name,
            .callback = callback,
            .ctx = ctx,
        });
        return self.app_listeners.items.len - 1;
    }

    pub fn removeAppListener(self: *Exchange, index: usize) void {
        if (index >= self.app_listeners.items.len) return;
        _ = self.app_listeners.orderedRemove(index);
    }

    /// Removes the listener registered at `index`, if it is still there. The
    /// slot is emptied rather than shifted so other indices stay valid.
    pub fn removePageListener(self: *Exchange, index: usize) void {
        if (index >= self.page_listeners.items.len) return;
        _ = self.page_listeners.orderedRemove(index);
    }

    /// Counts how many listeners an event name has, for tests and diagnostics.
    pub fn pageListenerCount(self: *const Exchange, name: []const u8) usize {
        var n: usize = 0;
        for (self.page_listeners.items) |l| {
            if (std.mem.eql(u8, l.name, name)) n += 1;
        }
        return n;
    }

    /// Runs every listener registered for the event's name.
    ///
    /// The payload borrows the message text, which is why the callback runs
    /// before `deliver` returns and may not keep a reference to it.
    fn deliverPageEvent(self: *Exchange, window: u32, ev: protocol.Incoming.PageEvent) void {
        for (self.page_listeners.items) |l| {
            if (!std.mem.eql(u8, l.name, ev.name)) continue;
            l.callback(l.ctx, window, ev.data);
        }
    }

    const SubSet = std.ArrayListUnmanaged([]const u8);
    const CancelKey = struct { window: u32, id: u32 };

    pub fn init(allocator: std.mem.Allocator) Exchange {
        return .{
            .allocator = allocator,
            .registry = service.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *Exchange) void {
        self.page_listeners.deinit(self.allocator);
        var it = self.subscriptions.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |name| self.allocator.free(name);
            e.value_ptr.deinit(self.allocator);
        }
        self.subscriptions.deinit(self.allocator);
        self.cancelled.deinit(self.allocator);
        self.registry.deinit();
    }

    pub fn attach(self: *Exchange, sink: Sink) void {
        self.sink = sink;
    }

    /// Called when a window goes away.
    pub fn forgetWindow(self: *Exchange, window: u32) void {
        if (self.subscriptions.fetchRemove(window)) |kv| {
            var set = kv.value;
            for (set.items) |name| self.allocator.free(name);
            set.deinit(self.allocator);
        }
        var it = self.cancelled.keyIterator();
        var doomed: [64]CancelKey = undefined;
        while (true) {
            var n: usize = 0;
            while (it.next()) |k| {
                if (k.window != window) continue;
                if (n == doomed.len) break;
                doomed[n] = k.*;
                n += 1;
            }
            if (n == 0) break;
            for (doomed[0..n]) |k| _ = self.cancelled.remove(k);
            it = self.cancelled.keyIterator();
        }
    }

    // ------------------------------------------------------------- inbound

    /// Handles one message from a page. `text` is the raw string the bridge
    /// posted; it may be a single message or a batch.
    pub fn deliver(self: *Exchange, window: u32, text: []const u8) void {
        // Parsing borrows `text`, so every value below is valid until this
        // function returns. Replies are built into `out` during that window and
        // sent before it ends.
        var parser = json.Parser.init(self.allocator, text);
        defer parser.deinit();

        const root = parser.parse() catch |e| {
            log.debug("ipc: unparseable message from window {d}: {s}", .{ window, @errorName(e) });
            return;
        };

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        self.allocator.free(out.items[0..0]);
        var wrote_any = false;

        switch (root) {
            .array => |items| {
                for (items) |item| {
                    if (self.handle(window, item, &out)) wrote_any = true;
                }
            },
            // The bridge batches everything the page sent in one microtask, so
            // a burst of calls arrives as one message.
            .object => |obj| blk: {
                const is_batch = blk2: {
                    const t = field(obj, "t") orelse break :blk2 false;
                    break :blk2 switch (t) {
                        .string => |name| std.mem.eql(u8, name, "batch"),
                        else => false,
                    };
                };
                if (is_batch) {
                    const m = field(obj, "m") orelse break :blk;
                    switch (m) {
                        .array => |items| for (items) |item| {
                            if (self.handle(window, item, &out)) wrote_any = true;
                        },
                        else => {},
                    }
                    break :blk;
                }
                if (self.handle(window, root, &out)) wrote_any = true;
            },
            else => {
                if (self.handle(window, root, &out)) wrote_any = true;
            },
        }

        if (wrote_any) self.send(window, out.items);
    }

    /// Handles one message, appending a reply to `out` when the message needs
    /// one. Returns true when `out` changed.
    fn handle(self: *Exchange, window: u32, value: json.Value, out: *std.ArrayList(u8)) bool {
        const msg = protocol.Incoming.parse(value) orelse return false;
        switch (msg) {
            .subscribe => |name| {
                self.subscribe(window, name) catch {
                    log.warn("ipc: cannot track subscription to '{s}'", .{name});
                };
                return false;
            },
            .unsubscribe => |name| {
                self.unsubscribe(window, name);
                return false;
            },
            .cancel => |id| {
                self.recordCancel(window, id);
                return false;
            },
            .page_event => |ev| {
                // Forwarded to the application's listeners. Nothing is answered:
                // the page's `emit` returns void, so a reply would be noise.
                self.deliverPageEvent(window, ev);
                return false;
            },
            .call => |call| {
                // A call whose id was already cancelled is answered up front,
                // so the page's promise settles instead of hanging.
                if (self.cancelled.fetchRemove(.{ .window = window, .id = call.id }) != null) {
                    // Answering consumes the record, so a later call reusing
                    // this id is not refused.
                    self.appendError(out, call.id, .cancelled, "the call was cancelled") catch {};
                    return true;
                }
                var call_args = decode.Args.init(call.args);
                call_args.sender = window;
                const result = self.registry.call(call.method, call_args);
                switch (result) {
                    .ok => |v| self.appendOk(out, call.id, v) catch return false,
                    .ok_raw => |text| self.appendOkRaw(out, call.id, text) catch return false,
                    .err => |f| self.appendError(out, call.id, f.code, f.message) catch return false,
                }
                // The page cancelled while the handler ran: the reply is
                // dropped, which is what cancelling means from the page.
                if (self.cancelled.fetchRemove(.{ .window = window, .id = call.id }) != null) {
                    return false;
                }
                return true;
            },
        }
    }

    fn appendOk(self: *Exchange, out: *std.ArrayList(u8), id: u32, value: json.Value) !void {
        if (out.items.len > 0) try out.append(self.allocator, ',');
        try out.appendSlice(self.allocator, "{\"t\":\"ok\",\"id\":");
        try self.appendU32(out, id);
        try out.appendSlice(self.allocator, ",\"v\":");
        try value.encode(self.allocator, out);
        try out.append(self.allocator, '}');
    }

    fn appendOkRaw(self: *Exchange, out: *std.ArrayList(u8), id: u32, text: []const u8) !void {
        if (out.items.len > 0) try out.append(self.allocator, ',');
        try out.appendSlice(self.allocator, "{\"t\":\"ok\",\"id\":");
        try self.appendU32(out, id);
        try out.appendSlice(self.allocator, ",\"v\":");
        try out.appendSlice(self.allocator, text);
        try out.append(self.allocator, '}');
    }

    fn appendError(
        self: *Exchange,
        out: *std.ArrayList(u8),
        id: u32,
        code: protocol.Code,
        message: []const u8,
    ) !void {
        if (out.items.len > 0) try out.append(self.allocator, ',');
        try out.appendSlice(self.allocator, "{\"t\":\"err\",\"id\":");
        try self.appendU32(out, id);
        try out.appendSlice(self.allocator, ",\"c\":\"");
        try out.appendSlice(self.allocator, code.name());
        try out.appendSlice(self.allocator, "\",\"m\":");
        var esc: std.ArrayList(u8) = .empty;
        defer esc.deinit(self.allocator);
        try encodeString(self.allocator, &esc, message);
        try out.appendSlice(self.allocator, esc.items);
        try out.append(self.allocator, '}');
    }

    fn field(obj: []const json.Field, key: []const u8) ?json.Value {
        for (obj) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }

    fn appendU32(self: *Exchange, out: *std.ArrayList(u8), value: u32) !void {
        var buf: [10]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try out.appendSlice(self.allocator, text);
    }

    fn send(self: *Exchange, window: u32, batch: []const u8) void {
        const s = self.sink orelse return;
        // A batch is a JSON array; wrap it in the page's receive call. The
        // array is passed as a JSON literal, not a string, to avoid a second
        // encode/decode round trip in the page.
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(self.allocator);
        // `batch` holds the contents of one JSON array, without its brackets:
        // each reply and event writes its own object, and the brackets belong
        // here. A missing `]` makes the call an unterminated array literal, so
        // every reply would be a parse error in the page.
        code.appendSlice(self.allocator, "window.__myzig && window.__myzig.receive([") catch return;
        code.appendSlice(self.allocator, batch) catch return;
        code.appendSlice(self.allocator, "])") catch return;
        _ = s.eval(s.ctx, window, code.items);
    }

    // ------------------------------------------------------------ outbound

    /// Collects every window subscribed to `name` and writes one event message
    /// per window. Returns how many windows were addressed.
    ///
    /// The payload is encoded once per window; it is not shared because each
    /// page needs its own copy in its own heap.
    pub fn emit(self: *Exchange, name: []const u8, payload: json.Value) usize {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var sent: usize = 0;
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            const window = entry.key_ptr.*;
            if (!subSetContains(entry.value_ptr, name)) continue;

            out.clearRetainingCapacity();
            out.appendSlice(self.allocator, "{\"t\":\"ev\",\"e\":") catch continue;
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(self.allocator);
            encodeString(self.allocator, &tmp, name) catch continue;
            out.appendSlice(self.allocator, tmp.items) catch continue;
            out.appendSlice(self.allocator, ",\"d\":") catch continue;
            payload.encode(self.allocator, &out) catch continue;
            out.appendSlice(self.allocator, "}") catch continue;

            self.send(window, out.items);
            sent += 1;
        }

        // The application hears its own events too. A window of 0 means the
        // listener does not care which window caused it, which is what a menu
        // click is.
        for (self.app_listeners.items) |listener| {
            if (!std.mem.eql(u8, listener.name, name)) continue;
            listener.callback(listener.ctx, 0, payload);
        }
        return sent;
    }

    /// True when the page asked to cancel `id` on `window`.
    pub fn isCancelled(self: *const Exchange, window: u32, id: u32) bool {
        return self.cancelled.contains(.{ .window = window, .id = id });
    }

    // --------------------------------------------------------- subscriptions

    fn subscribe(self: *Exchange, window: u32, name: []const u8) !void {
        const gop = try self.subscriptions.getOrPut(self.allocator, window);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (subSetContains(gop.value_ptr, name)) return;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try gop.value_ptr.append(self.allocator, owned);
    }

    fn unsubscribe(self: *Exchange, window: u32, name: []const u8) void {
        const set = self.subscriptions.getPtr(window) orelse return;
        for (set.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item, name)) continue;
            self.allocator.free(item);
            _ = set.orderedRemove(i);
            return;
        }
    }

    fn recordCancel(self: *Exchange, window: u32, id: u32) void {
        // A page that cancels thousands of ids would otherwise grow this map
        // without limit; past the cap, the oldest entries stop being tracked,
        // which only loses a dropped reply, never correctness of a running
        // handler.
        if (self.cancelled.count() >= 4096) {
            var it = self.cancelled.keyIterator();
            if (it.next()) |first| _ = self.cancelled.remove(first.*);
        }
        self.cancelled.put(self.allocator, .{ .window = window, .id = id }, {}) catch {};
    }
};

/// Linear scan over a window's subscription list. A window subscribes to a
/// handful of events, so a scan beats the bookkeeping of a set here.
fn subSetContains(set: *const Exchange.SubSet, name: []const u8) bool {
    for (set.items) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

/// Appends `s` as a JSON string literal, delegating to the JSON writer so
/// escaping is identical everywhere.
fn encodeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try json.encodeString(allocator, out, s);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

pub fn arithAdd(ctx: ?*anyopaque, args: decode.Args) protocol.Result {
    // A returned `json.Value` must outlive the handler: the exchange encodes
    // it after the handler returns. A slice into a local buffer would be
    // dangling, so numbers are decoded and re-serialised by the scorer, which
    // holds the text in the recorder.
    const self: *Scored = @ptrCast(@alignCast(ctx.?));
    var a = args;
    const x = a.int(i64, .{}) catch |e| return decode.Args.toResult(e);
    const y = a.int(i64, .{}) catch |e| return decode.Args.toResult(e);
    self.text = std.fmt.bufPrint(&self.buf, "{d}", .{x + y}) catch
        return protocol.Result.fail(.internal, "overflow");
    return protocol.Result.success(.{ .number = self.text });
}

/// Holds a handler's output so it outlives the handler call.
pub const Scored = struct {
    buf: [32]u8 = undefined,
    text: []const u8 = "",
};

fn arithDiv(ctx: ?*anyopaque, args: decode.Args) protocol.Result {
    const self: *Scored = @ptrCast(@alignCast(ctx.?));
    var a = args;
    const x = a.int(i64, .{}) catch |e| return decode.Args.toResult(e);
    const y = a.int(i64, .{}) catch |e| return decode.Args.toResult(e);
    if (y == 0) return protocol.Result.fail(.invalid_argument, "division by zero");
    self.text = std.fmt.bufPrint(&self.buf, "{d}", .{@divTrunc(x, y)}) catch
        return protocol.Result.fail(.internal, "overflow");
    return protocol.Result.success(.{ .number = self.text });
}

/// Records what the exchange asked the page to run.
pub const Recorder = struct {
    buf: std.ArrayList(u8) = .empty,
    windows: std.ArrayList(u32) = .empty,
    calls: usize = 0,

    fn deinit(self: *Recorder, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.windows.deinit(allocator);
    }

    fn sink(self: *Recorder) Sink {
        return .{ .ctx = self, .eval = eval };
    }

    fn eval(ctx: ?*anyopaque, window: u32, code: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(testing.allocator, code) catch return false;
        self.windows.clearRetainingCapacity();
        self.windows.append(testing.allocator, window) catch return false;
        self.calls += 1;
        return true;
    }

    fn last(self: *const Recorder) []const u8 {
        return self.buf.items;
    }
};

fn newExchange(reg: *Exchange, rec: *Recorder) void {
    reg.attach(rec.sink());
}

test "a call is answered with a typed result" {
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"call\",\"id\":7,\"m\":\"Math.add\",\"a\":[2,40]}");
    try testing.expectEqual(@as(usize, 1), rec.calls);
    try testing.expectEqual(@as(u32, 1), rec.windows.items[0]);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "window.__myzig") != null);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"v\":42") != null);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"id\":7") != null);
}

test "a failing handler reports a code the page can branch on" {
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.div", .invoke = arithDiv, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"call\",\"id\":1,\"m\":\"Math.div\",\"a\":[1,0]}");
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"c\":\"invalid-argument\"") != null);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "division by zero") != null);
}

test "a batch is answered with one message" {
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    // The bridge wraps what the page sent in one microtask as a single
    // `batch` message. Two calls must produce exactly one reply crossing.
    ex.deliver(1, "{\"t\":\"batch\",\"m\":[{\"t\":\"call\",\"id\":1,\"m\":\"Math.add\",\"a\":[1,1]},{\"t\":\"call\",\"id\":2,\"m\":\"Math.add\",\"a\":[2,2]}]}");
    try testing.expectEqual(@as(usize, 1), rec.calls);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"v\":2") != null);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"v\":4") != null);
}

test "subscriptions decide who receives an event" {
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"sub\",\"e\":\"tick\"}");
    ex.deliver(2, "{\"t\":\"sub\",\"e\":\"other\"}");
    // A subscription alone sends nothing to the page.
    try testing.expectEqual(@as(usize, 0), rec.calls);

    const sent = ex.emit("tick", .{ .number = "5" });
    try testing.expectEqual(@as(usize, 1), sent);
    try testing.expectEqual(@as(u32, 1), rec.windows.items[0]);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"e\":\"tick\"") != null);
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"d\":5") != null);
}

test "unsubscribe stops delivery" {
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"sub\",\"e\":\"tick\"}");
    ex.deliver(1, "{\"t\":\"unsub\",\"e\":\"tick\"}");
    try testing.expectEqual(@as(usize, 0), ex.emit("tick", .null));
}

test "a closed window stops receiving events" {
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"sub\",\"e\":\"tick\"}");
    ex.deliver(3, "{\"t\":\"sub\",\"e\":\"tick\"}");
    ex.forgetWindow(1);
    try testing.expectEqual(@as(usize, 1), ex.emit("tick", .null));
    try testing.expectEqual(@as(u32, 3), rec.windows.items[0]);
}

test "a cancelled call is answered without running the handler" {
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"cancel\",\"id\":5}");
    try testing.expect(ex.isCancelled(1, 5));
    ex.deliver(1, "{\"t\":\"call\",\"id\":5,\"m\":\"Math.add\",\"a\":[1,1]}");
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"c\":\"cancelled\"") != null);
    // Answering consumes the record, so a later call with the same id runs
    // normally instead of being refused forever.
    try testing.expect(!ex.isCancelled(1, 5));
    ex.deliver(1, "{\"t\":\"call\",\"id\":5,\"m\":\"Math.add\",\"a\":[1,1]}");
    try testing.expect(std.mem.indexOf(u8, rec.last(), "\"v\":2") != null);
}

test "messages from a page that is closed are dropped" {
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    // Unknown window: the eval sink decides, and here it simply records.
    ex.deliver(999, "{\"t\":\"call\",\"id\":1,\"m\":\"Math.add\",\"a\":[1,1]}");
    try testing.expectEqual(@as(usize, 1), rec.calls);
    ex.forgetWindow(999);
}

test "garbage from a page does not crash the framework" {
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    for ([_][]const u8{ "", "null", "{", "{\"t\":\"call\"}", "[[[" }) |bad| {
        ex.deliver(1, bad);
    }
    try testing.expectEqual(@as(usize, 0), rec.calls);
}

test "event payloads are escaped" {
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"sub\",\"e\":\"say\"}");
    _ = ex.emit("say", .{ .string = "quote\" and \\ backslash" });
    try testing.expect(std.mem.indexOf(u8, rec.last(), "quote\\\" and \\\\ backslash") != null);
}

test "an event reaches the page as a single well-formed call" {
    // Regression: the batch was already a complete JSON array, and the sender
    // appended an extra `]`, so every event arrived as a syntax error and no
    // subscriber ever fired.
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    try ex.subscribe(1, "menu:command");
    const sent = ex.emit("menu:command", .{ .string = "file.new" });
    try testing.expectEqual(@as(usize, 1), sent);

    const code = rec.last();
    try testing.expect(std.mem.startsWith(u8, code, "window.__myzig && window.__myzig.receive("));
    try testing.expect(std.mem.endsWith(u8, code, ")"));

    // Exactly one array, and it parses back to the message the page expects.
    const inner = code["window.__myzig && window.__myzig.receive(".len .. code.len - 1];
    // The batch ends with exactly one `]`: a second one is the bug this test
    // covers, and it shows up as `...]]`.
    try testing.expect(!std.mem.endsWith(u8, inner, "]]"));
    var parsed = try json.parse(testing.allocator, inner);
    defer parsed.parser.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.array.len);
}

test "a reply reaches the page as a single well-formed call" {
    // Regression: `send` wrapped the reply in `receive(` ... `)`, but the reply
    // builder never closed the JSON array it opened, so every answer arrived as
    // `receive([{...})` and the page threw a SyntaxError instead of resolving
    // the call. A structured clone and a round trip are both checked.
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"call\",\"id\":3,\"m\":\"Math.add\",\"a\":[9,3]}");
    try testing.expectEqual(@as(usize, 1), rec.calls);

    const code = rec.last();
    try testing.expect(std.mem.startsWith(u8, code, "window.__myzig && window.__myzig.receive(["));
    try testing.expect(std.mem.endsWith(u8, code, "])"));

    const inner = code["window.__myzig && window.__myzig.receive(".len .. code.len - 1];
    var parsed = try json.parse(testing.allocator, inner);
    defer parsed.parser.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.array.len);
    try testing.expectEqualStrings("ok", parsed.value.array[0].get("t").?.string);
    try testing.expectEqualStrings("12", parsed.value.array[0].get("v").?.number);
}

test "two replies in one batch are separated by exactly one comma" {
    // A batch carries several messages: the first must not start with a comma
    // and the bracket bookkeeping must not leak into the JSON.
    var scored = Scored{};
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    try ex.registry.add(.{ .name = "Math.add", .invoke = arithAdd, .arity = 2, .ctx = &scored });

    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    ex.deliver(1, "{\"t\":\"batch\",\"m\":[{\"t\":\"call\",\"id\":1,\"m\":\"Math.add\",\"a\":[8,2]},{\"t\":\"call\",\"id\":2,\"m\":\"Math.add\",\"a\":[6,3]}]}");
    try testing.expectEqual(@as(usize, 1), rec.calls);

    const code = rec.last();
    const inner = code["window.__myzig && window.__myzig.receive(".len .. code.len - 1];
    var parsed = try json.parse(testing.allocator, inner);
    defer parsed.parser.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.len);
    try testing.expectEqualStrings("10", parsed.value.array[0].get("v").?.number);
    try testing.expectEqualStrings("9", parsed.value.array[1].get("v").?.number);
}

test "an event from the page reaches the application" {
    // `window.myzig.emit` used to exist only in the generated TypeScript, so a
    // page could call it and nothing happened on the Zig side.
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    const Grab = struct {
        var got_name: [32]u8 = undefined;
        var got_len: usize = 0;
        var got_window: u32 = 0;
        var got_value: usize = 0;
        var seen: usize = 0;

        fn onEvent(_: ?*anyopaque, window: u32, payload: json.Value) void {
            got_window = window;
            got_value = payload.get("id").?.number.len;
            got_len = @min(payload.get("what").?.string.len, got_name.len);
            @memcpy(got_name[0..got_len], payload.get("what").?.string[0..got_len]);
            seen += 1;
        }
    };
    Grab.seen = 0;

    _ = try ex.addPageListener("ui:clicked", Grab.onEvent, null);
    try testing.expectEqual(@as(usize, 1), ex.pageListenerCount("ui:clicked"));

    ex.deliver(7, "{\"t\":\"cev\",\"e\":\"ui:clicked\",\"d\":{\"id\":42,\"what\":\"save\"}}");

    try testing.expectEqual(@as(usize, 1), Grab.seen);
    try testing.expectEqual(@as(u32, 7), Grab.got_window);
    try testing.expectEqualStrings("save", Grab.got_name[0..Grab.got_len]);
    try testing.expectEqual(@as(usize, 2), Grab.got_value);
    // A page event is not answered.
    try testing.expectEqual(@as(usize, 0), rec.calls);
}

test "listeners for other names are not called" {
    var ex = Exchange.init(testing.allocator);
    defer ex.deinit();
    var rec = Recorder{};
    defer rec.deinit(testing.allocator);
    newExchange(&ex, &rec);

    const Ignore = struct {
        var seen: usize = 0;
        fn onEvent(_: ?*anyopaque, _: u32, _: json.Value) void {
            seen += 1;
        }
    };

    const index = try ex.addPageListener("wanted", Ignore.onEvent, null);
    ex.deliver(1, "{\"t\":\"cev\",\"e\":\"other\",\"d\":null}");
    try testing.expectEqual(@as(usize, 0), Ignore.seen);

    ex.deliver(1, "{\"t\":\"cev\",\"e\":\"wanted\",\"d\":null}");
    try testing.expectEqual(@as(usize, 1), Ignore.seen);

    ex.removePageListener(index);
    try testing.expectEqual(@as(usize, 0), ex.pageListenerCount("wanted"));
    ex.deliver(1, "{\"t\":\"cev\",\"e\":\"wanted\",\"d\":null}");
    try testing.expectEqual(@as(usize, 1), Ignore.seen);
}

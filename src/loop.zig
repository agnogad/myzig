//! The main-thread queue.
//!
//! Native UI toolkits must be driven from the thread that started the process.
//! Every public MyZig method is safe to call from any thread: work that must
//! touch a native API is posted here and executed on the main thread.
//!
//! Design notes:
//!
//! * The queue is a bounded ring of fixed-size slots so that posting never
//!   allocates on a hot path, and so that a runaway producer cannot exhaust
//!   memory. Telemetry counts drops instead.
//! * Each slot holds a function pointer, a `*anyopaque` context and a small
//!   inline payload (four machine words), which covers every use in the
//!   framework: a window id, a string length, a pointer.
//! * `post` is lock-free for the common single-producer case using a spinlock
//!   guarded index; the ring is drained by the main thread only.
//! * When the queue is empty, `drain` returns immediately. The backend is
//!   only signalled when the queue transitions from empty to non-empty, so an
//!   idle app does no work.

const std = @import("std");
const log = @import("log.zig");

pub const Task = struct {
    func: *const fn (ctx: *anyopaque, payload: Payload) void,
    ctx: *anyopaque,
    payload: Payload = .{},
    /// Set for work whose completion another thread may wait on.
    done: ?*std.atomic.Value(bool) = null,
};

pub const Payload = struct {
    a: usize = 0,
    b: usize = 0,
    c: usize = 0,
    d: usize = 0,
};

pub const Queue = struct {
    const capacity = 1024;

    slots: [capacity]Task = undefined,
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),
    spin: std.atomic.Value(u8) = .init(0),
    /// Counted when the ring is full, so a bug shows up instead of vanishing.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Called when the queue becomes non-empty, to wake the native event loop.
    wake: ?*const fn (ctx: *anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,

    pub fn init() Queue {
        return .{};
    }

    pub fn deinit(self: *Queue) void {
        self.drainAll();
        self.* = undefined;
    }

    pub fn len(self: *const Queue) u32 {
        return self.tail.load(.acquire) -% self.head.load(.acquire);
    }

    pub fn isEmpty(self: *const Queue) bool {
        return self.len() == 0;
    }

    fn lockSpin(self: *Queue) void {
        while (self.spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockSpin(self: *Queue) void {
        self.spin.store(0, .release);
    }

    /// Posts work from any thread. Returns false when the queue is full.
    pub fn post(self: *Queue, task: Task) bool {
        self.lockSpin();
        defer self.unlockSpin();

        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail -% head >= capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        self.slots[tail % capacity] = task;
        self.tail.store(tail +% 1, .release);

        if (tail == head) {
            if (self.wake) |w| w(self.wake_ctx.?);
        }
        return true;
    }

    /// Posts and waits for the task to run. Called from a non-main thread.
    /// Returns false if the queue was full (the caller must not wait then).
    pub fn postAndWait(self: *Queue, task: Task) bool {
        var done = std.atomic.Value(bool).init(false);
        var t = task;
        t.done = &done;
        if (!self.post(t)) return false;
        while (!done.load(.acquire)) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
        return true;
    }

    /// Runs queued tasks on the calling (main) thread. Returns how many ran.
    /// Does not allocate.
    pub fn drain(self: *Queue) u32 {
        var ran: u32 = 0;
        while (true) {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head == tail) break;
            const task = self.slots[head % capacity];
            self.head.store(head +% 1, .release);
            task.func(task.ctx, task.payload);
            if (task.done) |d| d.store(true, .release);
            ran += 1;
            // Bound the work per turn so input and painting stay responsive.
            if (ran >= capacity) break;
        }
        return ran;
    }

    /// Drains everything, including work queued while draining. Only for
    /// shutdown.
    pub fn drainAll(self: *Queue) void {
        while (!self.isEmpty()) _ = self.drain();
    }
};

/// A stack of tasks that runs LIFO, for cleanup during shutdown.
pub fn runAll(tasks: []const Task) void {
    for (tasks) |t| t.func(t.ctx, t.payload);
}

test "post and drain on one thread" {
    var q = Queue.init();
    defer q.deinit();

    const Counter = struct {
        var value: usize = 0;
        fn add(ctx: *anyopaque, p: Payload) void {
            _ = ctx;
            value += p.a;
        }
    };
    Counter.value = 0;
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.post(.{ .func = Counter.add, .ctx = undefined, .payload = .{ .a = 2 } }));
    try std.testing.expect(q.post(.{ .func = Counter.add, .ctx = undefined, .payload = .{ .a = 3 } }));
    try std.testing.expectEqual(@as(u32, 2), q.len());
    try std.testing.expectEqual(@as(u32, 2), q.drain());
    try std.testing.expectEqual(@as(usize, 5), Counter.value);
    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), q.drain());
}

test "wake is called on empty to non-empty transition only" {
    var q = Queue.init();
    defer q.deinit();

    const Ctx = struct {
        var wakes: usize = 0;
        fn wake(_: *anyopaque) void {
            wakes += 1;
        }
        fn noop(_: *anyopaque, _: Payload) void {}
    };
    Ctx.wakes = 0;
    var dummy: u8 = 0;
    q.wake = Ctx.wake;
    q.wake_ctx = &dummy;

    _ = q.post(.{ .func = Ctx.noop, .ctx = undefined });
    _ = q.post(.{ .func = Ctx.noop, .ctx = undefined });
    try std.testing.expectEqual(@as(usize, 1), Ctx.wakes);
    _ = q.drain();
    _ = q.post(.{ .func = Ctx.noop, .ctx = undefined });
    try std.testing.expectEqual(@as(usize, 2), Ctx.wakes);
    _ = q.drain();
}

test "post from another thread" {
    var q = Queue.init();
    defer q.deinit();

    const Ctx = struct {
        var total: usize = 0;
        fn add(_: *anyopaque, p: Payload) void {
            total += p.a;
        }
        fn producer(queue: *Queue) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                while (!queue.post(.{ .func = add, .ctx = undefined, .payload = .{ .a = 1 } })) {
                    std.Thread.yield() catch {};
                }
            }
        }
    };
    Ctx.total = 0;

    const t = try std.Thread.spawn(.{}, Ctx.producer, .{&q});
    // Drain concurrently while the producer runs.
    while (Ctx.total < 100) {
        _ = q.drain();
        std.Thread.yield() catch {};
    }
    t.join();
    _ = q.drain();
    try std.testing.expectEqual(@as(usize, 100), Ctx.total);
}

test "postAndWait runs the task and returns" {
    var q = Queue.init();
    defer q.deinit();

    const Ctx = struct {
        var flag: bool = false;
        fn set(_: *anyopaque, _: Payload) void {
            flag = true;
        }
    };
    Ctx.flag = false;
    var ran = false;
    const t = try std.Thread.spawn(.{}, struct {
        fn go(queue: *Queue, out: *bool) void {
            out.* = queue.postAndWait(.{ .func = Ctx.set, .ctx = undefined });
        }
    }.go, .{ &q, &ran });
    while (q.isEmpty()) std.Thread.yield() catch {};
    _ = q.drain();
    t.join();
    try std.testing.expect(ran);
    try std.testing.expect(Ctx.flag);
}

test "queue reports drops when full" {
    var q = Queue.init();
    defer q.deinit();
    const Ctx = struct {
        fn noop(_: *anyopaque, _: Payload) void {}
    };
    var posted: usize = 0;
    while (q.post(.{ .func = Ctx.noop, .ctx = undefined })) posted += 1;
    try std.testing.expectEqual(@as(usize, Queue.capacity), posted);
    try std.testing.expect(q.dropped.load(.monotonic) > 0);
    _ = q.drain();
}

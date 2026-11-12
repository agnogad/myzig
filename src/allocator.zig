//! Allocator strategy.
//!
//! MyZig has no garbage collector. Every allocation belongs to exactly one
//! owner, and every public type states its ownership rules:
//!
//! * The [`Allocator`] handed to `App.init` is the **base allocator**. It
//!   must be a `std.mem.Allocator` the application owns and outlives the app
//!   with. The framework never frees memory it did not allocate.
//! * The framework keeps a **long-lived arena** (`app_arena`) for values that
//!   live as long as the application: config strings, service names, window
//!   registries. Freed in one call by `deinit`.
//! * Each window owns a **window arena** for its own long-lived values (title,
//!   url, webview config). Freed when the window is destroyed.
//! * Per-frame and per-message work uses a **scratch arena** that is reset
//!   between frames and between IPC messages. Nothing may escape it.
//! * Allocations that cross the IPC boundary are explicit: a handler that
//!   returns a string allocates it from the *reply allocator*, which follows
//!   the request's lifetime and is freed by the router after the reply is
//!   flushed.
//!
//! ## Rules
//!
//! 1. Functions that allocate take an `Allocator` and return the memory they
//!    own; the doc comment says who frees it.
//! 2. Functions that borrow never outlive the call and are marked `borrow`.
//! 3. Scratch memory is never stored in a struct field.
//! 4. An allocator stored in a struct is the *same* allocator used to free its
//!    memory; the struct stores it so `deinit` needs no argument.
//! 5. Nothing is allocated on the hot path: rendering, event dispatch and
//!    IPC decoding use preallocated buffers.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

/// A bump allocator that keeps its memory between resets, so steady-state
/// frames allocate nothing from the base allocator.
///
/// Used for per-frame scratch memory.
pub const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    /// The highest watermark seen, for tests and benchmarks.
    high_water: usize = 0,

    pub fn init(base: Allocator) Scratch {
        return .{ .arena = std.heap.ArenaAllocator.init(base) };
    }

    pub fn deinit(self: *Scratch) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Scratch) Allocator {
        return self.arena.allocator();
    }

    /// Frees nearly everything but keeps the backing buffer, so the next frame
    /// does not hit the base allocator when its shape repeats.
    pub fn reset(self: *Scratch) void {
        const used = self.arena.queryCapacity();
        if (used > self.high_water) self.high_water = used;
        _ = self.arena.reset(.retain_capacity);
    }

    /// Drops the buffer too, for when a window shrinks a lot.
    pub fn resetFree(self: *Scratch) void {
        _ = self.arena.reset(.free_all);
    }

    pub fn bytesUsed(self: *const Scratch) usize {
        return self.arena.queryCapacity();
    }
};

/// Counts allocations so tests can assert that a code path allocates nothing.
///
/// ```
/// var c = Counting.init(std.testing.allocator);
/// try do_work(c.allocator());
/// try std.testing.expectEqual(@as(usize, 0), c.allocations);
/// ```
pub const Counting = struct {
    child: Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    bytes: usize = 0,

    pub fn init(child: Allocator) Counting {
        return .{ .child = child };
    }

    pub fn allocator(self: *Counting) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        self.bytes += len;
        return self.child.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            self.allocations += 1;
            self.bytes += new_len - memory.len;
        }
        return self.child.rawResize(memory, ptr_align, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            self.allocations += 1;
            self.bytes += new_len - memory.len;
        }
        return self.child.rawRemap(memory, ptr_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, ptr_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        return self.child.rawFree(memory, ptr_align, ret_addr);
    }
};

/// Duplicates a string into `allocator`. The caller owns the result.
pub fn dupe(allocator: Allocator, s: []const u8) ![]u8 {
    return allocator.dupe(u8, s);
}

/// Duplicates into `allocator` only when the source is not already static.
/// `owned` is always owned by `allocator` afterwards.
pub fn dupeOptional(allocator: Allocator, s: ?[]const u8) !?[]const u8 {
    const v = s orelse return null;
    return try allocator.dupe(u8, v);
}

/// A string that is either static (borrowed for the program's life) or owned
/// by an allocator. Used by configuration fields so the common case of a
/// string literal allocates nothing.
pub const Str = struct {
    bytes: []const u8,
    owned: bool = false,

    pub const empty: Str = .{ .bytes = "" };

    pub fn literal(s: []const u8) Str {
        return .{ .bytes = s };
    }

    pub fn init(allocator: Allocator, s: []const u8) !Str {
        return .{ .bytes = try allocator.dupe(u8, s), .owned = true };
    }

    pub fn deinit(self: *Str, allocator: Allocator) void {
        if (self.owned) allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn slice(self: Str) []const u8 {
        return self.bytes;
    }
};

test "scratch retains capacity across resets" {
    var s = Scratch.init(std.testing.allocator);
    defer s.deinit();
    {
        const a = try s.allocator().alloc(u8, 64 * 1024);
        @memset(a, 0xab);
    }
    const first_capacity = s.bytesUsed();
    s.reset();
    try std.testing.expect(s.bytesUsed() == first_capacity);
    {
        const a = try s.allocator().alloc(u8, 1024);
        @memset(a, 0xcd);
    }
    s.reset();
    try std.testing.expect(s.bytesUsed() == first_capacity);
    try std.testing.expect(s.high_water <= first_capacity);
}

test "counting allocator detects allocation-free paths" {
    var c = Counting.init(std.testing.allocator);
    const a = c.allocator();
    {
        const buf = try a.alloc(u8, 16);
        a.free(buf);
    }
    try std.testing.expectEqual(@as(usize, 1), c.allocations);
    try std.testing.expectEqual(@as(usize, 1), c.frees);
    var s = Scratch.init(a);
    defer s.deinit();
    {
        // First use takes one buffer from the base allocator.
        const x = try s.allocator().alloc(u8, 32);
        x[0] = 0;
    }
    s.reset();
    const after_first = c.allocations;
    {
        // The reset retained the buffer, so the next frame allocates nothing.
        const x = try s.allocator().alloc(u8, 32);
        x[0] = 0;
    }
    try std.testing.expectEqual(after_first, c.allocations);
}

test "Str borrows literals and owns dupes" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var a = Str.literal("static");
    a.deinit(gpa); // no-op

    var b = try Str.init(gpa, "owned value");
    try std.testing.expect(b.owned);
    b.deinit(gpa);
}

test "dupe round trip" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const d = try dupe(gpa, "hello");
    defer gpa.free(d);
    try std.testing.expectEqualStrings("hello", d);
}

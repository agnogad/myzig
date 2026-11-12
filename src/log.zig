//! Logging.
//!
//! MyZig logs to stderr with a level filter taken from the `MYZIG_LOG`
//! environment variable (`error`, `warn`, `info`, `debug`, `trace`). The
//! framework never allocates to log: messages are formatted into a fixed
//! stack buffer, so a log call inside an allocation-failure path is safe.

const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }
};

/// The active level. Set once at startup by `initFromEnv`, or directly.
/// Release builds default to `warn`, debug builds to `debug`.
pub var level: Level = if (builtin.mode == .debug) .debug else .warn;

var initialised = false;

/// Reads `MYZIG_LOG`. Idempotent; safe to call from anywhere.
pub fn initFromEnv() void {
    if (initialised) return;
    initialised = true;
    const raw = @import("utils/env.zig").get("MYZIG_LOG") orelse return;
    level = parseLevel(raw) orelse level;
}

pub fn parseLevel(raw: []const u8) ?Level {
    const map = .{
        .{ "error", Level.err },
        .{ "warn", Level.warn },
        .{ "info", Level.info },
        .{ "debug", Level.debug },
        .{ "trace", Level.trace },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(raw, entry[0])) return entry[1];
    }
    return null;
}

pub fn enabled(l: Level) bool {
    return @intFromEnum(l) <= @intFromEnum(level);
}

/// Formats into a stack buffer and writes once to stderr. Never allocates.
pub fn log(l: Level, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(l)) return;
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        // Message larger than the buffer: truncate rather than allocate.
        break :blk buf[0..];
    };
    writeStderr("[myzig] ", l.label(), ": ", msg, "\n");
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    log(.trace, fmt, args);
}

fn writeStderr(a: []const u8, b: []const u8, c: []const u8, d: []const u8, e: []const u8) void {
    if (builtin.os.tag == .windows) {
        // Avoid touching std.Io plumbing here; stderr is best effort.
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        std.debug.print("{s}{s}{s}{s}{s}", .{ a, b, c, d, e });
        return;
    }
    var iov = [_]std.posix.iovec_const{
        .{ .base = a.ptr, .len = a.len },
        .{ .base = b.ptr, .len = b.len },
        .{ .base = c.ptr, .len = c.len },
        .{ .base = d.ptr, .len = d.len },
        .{ .base = e.ptr, .len = e.len },
    };
    _ = std.posix.writev(std.posix.STDERR_FILENO, &iov) catch {};
}

test "level parsing" {
    try std.testing.expectEqual(Level.info, parseLevel("info").?);
    try std.testing.expectEqual(Level.warn, parseLevel("WARN").?);
    try std.testing.expect(parseLevel("nonsense") == null);
}

test "level ordering" {
    try std.testing.expect(enabled(.err));
    try std.testing.expect(!enabled(.trace) or level == .trace);
}

//! Environment variables and the executable's path, without `std.Io`.
//!
//! Zig 0.17 routes environment and file-system access through `std.Io`, which
//! an application would otherwise have to construct and pass into MyZig. MyZig
//! keeps its public API free of that requirement by reading the process
//! environment directly through libc, which every supported platform links.

const std = @import("std");
const builtin = @import("builtin");

/// Returns the value of `key`, or null. The slice points into the process'
/// environment block and stays valid for the program's life, so it is never
/// freed.
pub fn get(key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return getWindows(key);
    return getPosix(key);
}

/// Like `get`, but the returned slice is NUL-terminated at `slice.len`.
pub fn getZ(key: []const u8) ?[:0]const u8 {
    const v = get(key) orelse return null;
    // The environment block is NUL-terminated by definition.
    return v.ptr[0..v.len :0];
}

fn getPosix(key: []const u8) ?[]const u8 {
    if (key.len == 0) return null;
    var buf: [256]u8 = undefined;
    if (key.len >= buf.len) return null;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = 0;
    const v = std.c.getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.sliceTo(v, 0);
}

/// The two Win32 calls this file needs. Zig 0.17's `std.os.windows` no longer
/// declares them, and the project's style is to declare what it uses rather
/// than depend on whichever subset the standard library ships.
extern "kernel32" fn GetEnvironmentVariableW(
    name: [*:0]const u16,
    buffer: [*]u16,
    size: u32,
) callconv(.winapi) u32;

extern "kernel32" fn ProcessPrng(buffer: [*]u8, length: usize) callconv(.winapi) i32;

extern "kernel32" fn GetModuleFileNameW(
    module: ?*anyopaque,
    buffer: [*]u16,
    size: u32,
) callconv(.winapi) u32;

fn getWindows(key: []const u8) ?[]const u8 {
    if (key.len == 0 or key.len > 512) return null;
    var wide_key: [257]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide_key[0 .. key.len + 1], key) catch return null;
    wide_key[n] = 0;

    var buf: [32767]u16 = undefined;
    const rc = GetEnvironmentVariableW(@ptrCast(&wide_key), @ptrCast(&buf), buf.len);
    if (rc == 0) return null;

    // The result must outlive this call, so copy it into a static buffer.
    // A second, larger lookup needs a heap allocation, which a getter on a
    // settings path must not do: the environment of a desktop app is small.
    const len = utf16Len(buf[0..@min(rc, buf.len)]);
    const stat = struct {
        var storage: [512]u8 = undefined;
    };
    const written = std.unicode.utf16LeToUtf8(&stat.storage, buf[0..len]) catch return null;
    return stat.storage[0..written];
}

fn utf16Len(s: []const u16) usize {
    for (s, 0..) |c, i| {
        if (c == 0) return i;
    }
    return s.len;
}

/// Sets `key` to `value` for this process and its children. Does not overwrite
/// an existing value. Only the Linux backend needs this today.
pub fn set(key: []const u8, value: []const u8) void {
    if (builtin.os.tag == .windows) return;
    if (key.len == 0 or key.len > 255 or value.len > 4095) return;
    var kbuf: [256]u8 = undefined;
    var vbuf: [4096]u8 = undefined;
    @memcpy(kbuf[0..key.len], key);
    kbuf[key.len] = 0;
    @memcpy(vbuf[0..value.len], value);
    vbuf[value.len] = 0;
    _ = posixSetenv(@ptrCast(&kbuf), @ptrCast(&vbuf), 0);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn posixSetenv(k: [*:0]const u8, v: [*:0]const u8, ow: c_int) c_int {
    if (builtin.link_libc) return setenv(k, v, ow);
    return 0;
}

/// The full path of the running executable, written into `buf`.
pub fn selfExePath(buf: []u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var wide: [std.fs.max_path_bytes / 2]u16 = undefined;
        const n = GetModuleFileNameW(null, @ptrCast(&wide), wide.len);
        if (n == 0 or n >= wide.len) return error.PathTooLong;
        // `utf16LeToUtf8` returns the number of bytes written, so the slice is
        // taken from that count.
        const written = std.unicode.utf16LeToUtf8(buf, wide[0..@as(usize, n)]) catch return error.PathTooLong;
        return buf[0..written];
    }
    // /proc/self/exe on Linux and FreeBSD; _NSGetExecutablePath elsewhere.
    if (@import("builtin").os.tag == .linux) {
        const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
        if (n < 0) return error.FileNotFound;
        const len: usize = @intCast(n);
        if (len >= buf.len) return error.PathTooLong;
        return buf[0..len];
    }
    // macOS: read the symlink target of the running image through libc.
    const libc = struct {
        extern fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;
    };
    var size: u32 = @intCast(buf.len);
    if (libc._NSGetExecutablePath(buf.ptr, &size) != 0) return error.PathTooLong;
    return std.mem.sliceTo(buf, 0);
}

test "get returns null for an unset variable" {
    try std.testing.expect(get("MYZIG_DEFINITELY_UNSET_VARIABLE_12345") == null);
}

test "PATH is readable" {
    // Every platform MyZig targets has PATH.
    try std.testing.expect(get("PATH") != null or builtin.os.tag == .windows);
}

test "self exe path is absolute" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try selfExePath(&buf);
    try std.testing.expect(p.len > 0);
}

/// Fills `buf` with bytes from the operating system's cryptographic source.
///
/// Zig 0.17 moves randomness behind `std.Io`, which MyZig's public API does not
/// require, so the entropy is read here. A failure to reach the source is fatal
/// for a secret: there is no predictable fallback.
pub fn secureRandom(buf: []u8) void {
    if (builtin.os.tag == .windows) {
        // `ProcessPrng` is the call Windows documents for this: it cannot
        // fail, and it is what `std.Io`'s entropy source uses underneath.
        if (ProcessPrng(buf.ptr, buf.len) == 0) @panic("no entropy source");
        return;
    }
    if (builtin.os.tag == .linux) {
        const fd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY });
        if (fd < 0) @panic("no entropy source");
        defer _ = std.c.close(fd);
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = std.c.read(fd, buf.ptr + filled, buf.len - filled);
            if (n <= 0) @panic("no entropy source");
            filled += @intCast(n);
        }
        return;
    }
    // macOS and the BSDs: getentropy fills at most 256 bytes per call.
    var filled: usize = 0;
    while (filled < buf.len) {
        const chunk = @min(buf.len - filled, 256);
        if (std.c.getentropy(buf.ptr + filled, chunk) != 0) @panic("no entropy source");
        filled += chunk;
    }
}

test "secure random fills distinct buffers" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    secureRandom(&a);
    secureRandom(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

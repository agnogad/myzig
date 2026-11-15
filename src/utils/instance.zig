//! One process at a time.
//!
//! `AppOptions.single_instance` promises that launching an application twice
//! brings the first copy forward rather than starting a second one. Enforcing
//! it needs a lock that the whole machine can see and that is released when the
//! holder dies, and every platform spells that differently:
//!
//! | platform | mechanism |
//! |---|---|
//! | Linux, macOS | `flock(LOCK_EX \| LOCK_NB)` on a lock file |
//! | Windows | a named mutex |
//!
//! The kernel releases a `flock` when the process exits, including when it is
//! killed, so a crash cannot leave a lock that stops the application from ever
//! starting again. A pid file would need staleness detection and would be wrong
//! the moment a pid is reused; this needs none.
//!
//! This module keeps the *decision* separate from the syscall, because the
//! syscall cannot be exercised in a test suite: a test that acquires the lock
//! and another that fails to acquire it need two processes, and the interesting
//! cases are the failures.

const std = @import("std");
const builtin = @import("builtin");

/// What a lock attempt means for the application.
pub const Outcome = enum {
    /// This process owns the lock and is the primary instance.
    primary,
    /// Another live process owns it: bring that one forward and exit.
    secondary,
    /// The lock could not be taken for a reason that is not "someone else has
    /// it": the browser-file system is full, the path is unwritable, the
    /// platform has no implementation.
    ///
    /// This is reported separately so the caller can run *anyway*. Starting
    /// twice is a cosmetic problem; refusing to start because a lock file could
    /// not be written would turn it into a broken application.
    unavailable,
};

/// Maps an `flock` result onto an outcome.
///
/// `flock` answers 0 on success and -1 on failure, and the reason is in
/// `errno`. Only `EWOULDBLOCK` means "another process holds it"; treating every
/// failure that way would make an unwritable data directory look like a second
/// copy already running, and the user would watch the application exit without
/// a window and with no explanation.
pub fn classify(err: std.c.E) Outcome {
    return switch (err) {
        .SUCCESS => .primary,
        // EWOULDBLOCK is EAGAIN on both platforms that take this path, and
        // only one of the two names exists in the enum.
        .AGAIN => .secondary,
        else => .unavailable,
    };
}

/// The name of the lock file for `app_name`.
///
/// The name goes into a path, so a slash or a backslash would place the file
/// somewhere unexpected — `../` would put it outside the data directory
/// entirely. They are replaced rather than rejected, so an application whose
/// display name contains one still gets single-instance behaviour.
pub fn lockFileName(buf: []u8, app_name: []const u8) ?[]const u8 {
    if (app_name.len == 0) return null;
    const suffix = ".lock";
    if (buf.len < app_name.len + suffix.len) return null;
    for (app_name, 0..) |ch, i| {
        buf[i] = switch (ch) {
            '/', '\\' => '-',
            0 => '-',
            else => ch,
        };
    }
    @memcpy(buf[app_name.len..][0..suffix.len], suffix);
    return buf[0 .. app_name.len + suffix.len];
}

/// What a `CreateMutexW` result means.
///
/// The trap: a **non-null handle does not mean "another instance"**. Creating a
/// brand-new mutex also succeeds and hands back a handle. Only
/// `ERROR_ALREADY_EXISTS` in `GetLastError` says the name was already taken, and
/// that requires calling `GetLastError` *immediately* after the create call —
/// anything in between could overwrite it.
pub fn classifyWindows(handle_is_null: bool, last_error: u32) Outcome {
    if (handle_is_null) {
        // The name was malformed or the process is out of handles. Neither
        // means a second copy is running.
        return .unavailable;
    }
    const ffi = @import("../platform/windows/ffi.zig");
    return if (last_error == ffi.ERROR_ALREADY_EXISTS) .secondary else .primary;
}

/// Whether this platform can enforce single-instance.
///
/// Answering `true` where there is no implementation would let the application
/// believe it is protected when it is not, which is worse than saying so.
pub fn supported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

/// Holds the host-wide lock. Kept for the life of the application; closing the
/// file releases the lock.
///
/// POSIX holds a file descriptor and Windows holds a mutex handle; only one of
/// the two is meaningful on a given platform, and the other stays at its
/// "nothing held" value. Both are plain integers of the same width, so the
/// struct needs no conditional on most of its uses.
pub const Lock = struct {
    /// `flock` descriptor on POSIX, mutex handle on Windows. Held as an integer
    /// rather than `std.posix.fd_t` because that type is a pointer on Windows
    /// and an integer on POSIX, and the "nothing held" value has to be the same
    /// expression on both. `-1` (POSIX) and `0` (Windows) both mean unheld,
    /// which is what makes `deinit` safe to call unconditionally.
    fd: i64 = -1,

    /// True when this process holds the lock.
    held: bool = false,

    /// Tries to take the lock at `path`.
    ///
    /// The file is opened `O_RDWR | O_CREAT` and never truncated: `flock` is
    /// attached to the open file, not its contents, so there is no need to
    /// write a pid into it, and leaving whatever is there alone means two
    /// processes racing to create it cannot corrupt each other's data.
    pub fn acquire(self: *Lock, path: [:0]const u8) Outcome {
        if (!supported()) return .unavailable;
        if (builtin.os.tag == .windows) return self.acquireWindows(path);

        // Created if absent, never truncated: the lock lives on the open file
        // description, not in the file's contents.
        const raw = std.c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (@as(std.c.E, std.c.errno(raw)) != .SUCCESS) {
            // The directory is missing, not writable, or the file system is
            // full. None of that means a second copy is running.
            return .unavailable;
        }
        const fd: i64 = @intCast(raw);

        const rc = std.c.flock(@intCast(fd), std.c.LOCK.EX | std.c.LOCK.NB);
        const outcome = classify(std.c.errno(rc));

        if (outcome != .primary) {
            // The descriptor is not needed when the lock was not taken; holding
            // it open would keep the file alive for no reason.
            _ = std.c.close(@intCast(fd));
            return outcome;
        }

        // The descriptor must outlive this call: closing it releases the lock.
        self.fd = fd;
        self.held = true;
        return Outcome.primary;
    }

    /// The Windows path: a named mutex built from the lock file's name.
    ///
    /// `path` is a path on POSIX; on Windows only its last component is used,
    /// so the same `lockFileName` helper on both sides keeps one naming rule.
    /// The name is prefixed with `Local\\` so it is scoped to the login session:
    /// two users on one machine each get their own instance, which is what a
    /// desktop application means by "already running".
    fn acquireWindows(self: *Lock, path: [:0]const u8) Outcome {
        const ffi = @import("../platform/windows/ffi.zig");
        const base = std.fs.path.basename(path);

        var wide: [ffi.MAX_PATH_UNITS + 1]u16 = undefined;
        var name_buf: [ffi.MAX_PATH_UNITS + 1]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Local\\{s}", .{base}) catch return .unavailable;

        // Windows truncates an over-long object name instead of refusing it,
        // and a truncated name collides with another application's mutex. It is
        // refused here so the failure is visible instead of silent.
        const units = ffi.utf16Len(name) orelse return .unavailable;
        if (units >= ffi.MAX_PATH_UNITS) return .unavailable;

        const name_z = ffi.utf16(&wide, name) orelse return .unavailable;
        const handle = ffi.CreateMutexW(null, 0, name_z);
        // Read immediately: any other Win32 call could overwrite the error.
        const last_error = ffi.GetLastError();

        const outcome = classifyWindows(handle == null, last_error);
        switch (outcome) {
            .primary => {
                self.fd = @intCast(@intFromPtr(handle.?));
                self.held = true;
                return .primary;
            },
            .secondary => {
                // The handle still refers to the existing mutex and closing it
                // is correct: this process did not create it and holds no claim.
                if (handle) |h| _ = ffi.CloseHandle(h);
                return .secondary;
            },
            .unavailable => {
                if (handle) |h| _ = ffi.CloseHandle(h);
                return .unavailable;
            },
        }
    }

    /// Releases the lock and closes the file. Safe on an unheld lock, because
    /// `deinit` runs whether or not `acquire` succeeded.
    pub fn deinit(self: *Lock) void {
        if (builtin.os.tag == .windows) {
            if (self.fd > 0) {
                const ffi = @import("../platform/windows/ffi.zig");
                // Closing the last handle destroys the mutex, which is what
                // releases the name for the next launch.
                _ = ffi.CloseHandle(@ptrFromInt(@as(usize, @intCast(self.fd))));
                self.fd = -1;
            }
            self.held = false;
            return;
        }
        if (self.fd >= 0) {
            _ = std.c.flock(@intCast(self.fd), std.c.LOCK.UN);
            _ = std.c.close(@intCast(self.fd));
            self.fd = -1;
        }
        self.held = false;
    }
};

test "a held lock is the primary instance" {
    try std.testing.expectEqual(Outcome.primary, classify(.SUCCESS));
}

test "a would-block lock means someone else is running" {
    try std.testing.expectEqual(Outcome.secondary, classify(.AGAIN));
}

test "other failures are availability, not a second instance" {
    // A denied or missing directory both mean the lock file could not be made.
    // Reporting `.secondary` here would silently exit an application whose data
    // directory is not writable, with no window and no message.
    try std.testing.expectEqual(Outcome.unavailable, classify(.ACCES));
    try std.testing.expectEqual(Outcome.unavailable, classify(.NOENT));
    try std.testing.expectEqual(Outcome.unavailable, classify(.NOSPC));
    try std.testing.expectEqual(Outcome.unavailable, classify(.INVAL));
}

test "the lock file name is a file name, not a path" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("Note.lock", lockFileName(&buf, "Note").?);

    // A separator would escape the data directory, and `..` especially so.
    try std.testing.expectEqualStrings("a-b.lock", lockFileName(&buf, "a/b").?);
    try std.testing.expectEqualStrings("a-b.lock", lockFileName(&buf, "a\\b").?);
    try std.testing.expectEqualStrings("..-..-etc-passwd.lock", lockFileName(&buf, "../../etc/passwd").?);

    // An empty name cannot be turned into a file, and the caller falls back to
    // running without a lock.
    try std.testing.expectEqual(@as(?[]const u8, null), lockFileName(&buf, ""));

    // A name too long for the buffer is refused rather than truncated, since a
    // truncated name could collide with another application's.
    var small: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), lockFileName(&small, "application"));
}

test "a lock with no descriptor is harmless to release" {
    var lock = Lock{};
    lock.deinit();
    try std.testing.expect(!lock.held);
}

test "unsupported platforms say so" {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try std.testing.expect(supported());
    } else {
        try std.testing.expect(!supported());
    }
}

test "a null mutex handle is never 'another instance is running'" {
    // `CreateMutexW` returns a handle for a *new* mutex as well as an existing
    // one, so the handle cannot answer the question. A null handle means the
    // name was rejected, which is a reason to run unlocked, not to exit.
    try std.testing.expectEqual(Outcome.unavailable, classifyWindows(true, 0));
    try std.testing.expectEqual(Outcome.unavailable, classifyWindows(true, 5));
}

test "a fresh mutex is the primary instance" {
    // The case the API makes easy to get wrong: a valid handle with no
    // ERROR_ALREADY_EXISTS means this process created the name.
    try std.testing.expectEqual(Outcome.primary, classifyWindows(false, 0));
}

test "ERROR_ALREADY_EXISTS is the only signal for a second copy" {
    // 183 is documented for ERROR_ALREADY_EXISTS; the value is asserted rather
    // than imported so a wrong number here fails instead of silently making
    // every launch look like the first one.
    try std.testing.expectEqual(Outcome.secondary, classifyWindows(false, 183));

    // Every neighbouring error means something else went wrong.
    try std.testing.expectEqual(Outcome.primary, classifyWindows(false, 5)); // ACCESS_DENIED
    try std.testing.expectEqual(Outcome.primary, classifyWindows(false, 87)); // INVALID_PARAMETER
}

test "Windows is a platform single-instance is written for" {
    // The table and the code have to agree: `supported()` true with no
    // implementation would leave an application believing it is protected.
    if (builtin.os.tag == .windows) {
        try std.testing.expect(supported());
    }
}

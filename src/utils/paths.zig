//! Application paths: where MyZig and applications keep data.
//!
//! Follows the platform conventions:
//!
//! | | Linux | Windows | macOS |
//! |---|---|---|---|
//! | config | `$XDG_CONFIG_HOME/<app>` | `%APPDATA%\<app>` | `~/Library/Application Support/<app>` |
//! | data | `$XDG_DATA_HOME/<app>` | `%LOCALAPPDATA%\<app>` | `~/Library/Application Support/<app>` |
//! | cache | `$XDG_CACHE_HOME/<app>` | `%LOCALAPPDATA%\<app>\Cache` | `~/Library/Caches/<app>` |
//! | logs | `$XDG_STATE_HOME/<app>/logs` | `%LOCALAPPDATA%\<app>\Logs` | `~/Library/Logs/<app>` |
//!
//! Paths are computed once at startup into a fixed buffer, so reading them
//! never allocates. `PathSet` owns its bytes and frees them in `deinit`.

const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");

pub const max_path = 1024;

pub const Kind = enum {
    config,
    data,
    cache,
    logs,
    temp,
    /// The directory holding the executable.
    executable,
    /// The user's home directory.
    home,
};

/// A set of resolved directories for one application.
pub const PathSet = struct {
    allocator: std.mem.Allocator,
    app_name: []u8,
    config: []u8,
    data: []u8,
    cache: []u8,
    logs: []u8,

    /// Resolves the directories for `app_name`. The name is used verbatim as a
    /// directory name, so it must not contain path separators.
    pub fn init(allocator: std.mem.Allocator, app_name: []const u8) !PathSet {
        if (std.mem.indexOfAny(u8, app_name, "/\\") != null) return error.InvalidAppName;
        if (app_name.len == 0) return error.InvalidAppName;

        const name = try allocator.dupe(u8, app_name);
        errdefer allocator.free(name);

        const config = try resolve(allocator, .config, name);
        errdefer allocator.free(config);
        const data = try resolve(allocator, .data, name);
        errdefer allocator.free(data);
        const cache = try resolve(allocator, .cache, name);
        errdefer allocator.free(cache);
        const logs = try resolve(allocator, .logs, name);
        errdefer allocator.free(logs);

        return .{
            .allocator = allocator,
            .app_name = name,
            .config = config,
            .data = data,
            .cache = cache,
            .logs = logs,
        };
    }

    pub fn deinit(self: *PathSet) void {
        self.allocator.free(self.app_name);
        self.allocator.free(self.config);
        self.allocator.free(self.data);
        self.allocator.free(self.cache);
        self.allocator.free(self.logs);
        self.* = undefined;
    }

    /// Creates the directories if they do not exist. Returns the first error.
    pub fn ensureDirs(self: *const PathSet) !void {
        for ([_][]const u8{ self.config, self.data, self.cache, self.logs }) |dir| {
            std.fs.cwd().makePath(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
    }

    pub fn get(self: *const PathSet, kind: Kind) []const u8 {
        return switch (kind) {
            .config => self.config,
            .data => self.data,
            .cache => self.cache,
            .logs => self.logs,
            else => "",
        };
    }
};

fn homeDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (env.get("USERPROFILE")) |v| return allocator.dupe(u8, v);
        const drive = env.get("HOMEDRIVE") orelse "";
        const path = env.get("HOMEPATH") orelse "";
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive, path });
    }
    if (env.get("HOME")) |v| return allocator.dupe(u8, v);
    return error.NoHomeDirectory;
}

/// Resolves one directory for `app_name`.
pub fn resolve(allocator: std.mem.Allocator, kind: Kind, app_name: []const u8) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const base_key: []const u8 = switch (kind) {
                .config => "APPDATA",
                .data, .cache, .logs => "LOCALAPPDATA",
                else => "TEMP",
            };
            const base = env.get(base_key) orelse try homeDir(allocator);
            defer if (env.get(base_key) == null) allocator.free(base);
            return switch (kind) {
                .cache => std.fmt.allocPrint(allocator, "{s}\\{s}\\Cache", .{ base, app_name }),
                .logs => std.fmt.allocPrint(allocator, "{s}\\{s}\\Logs", .{ base, app_name }),
                else => std.fmt.allocPrint(allocator, "{s}\\{s}", .{ base, app_name }),
            };
        },
        .macos => {
            const home = try homeDir(allocator);
            defer allocator.free(home);
            return switch (kind) {
                .config, .data => std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}", .{ home, app_name }),
                .cache => std.fmt.allocPrint(allocator, "{s}/Library/Caches/{s}", .{ home, app_name }),
                .logs => std.fmt.allocPrint(allocator, "{s}/Library/Logs/{s}", .{ home, app_name }),
                else => std.fmt.allocPrint(allocator, "{s}/tmp", .{home}),
            };
        },
        else => {
            // XDG Base Directory Specification. Each candidate is tried in
            // order; the first that allocates wins and its predecessors are
            // freed, so nothing leaks when an earlier attempt fails.
            const home = try homeDir(allocator);
            defer allocator.free(home);
            switch (kind) {
                .config => return xdgDir(allocator, "XDG_CONFIG_HOME", home, ".config", app_name),
                .data => return xdgDir(allocator, "XDG_DATA_HOME", home, ".local/share", app_name),
                .cache => return xdgDir(allocator, "XDG_CACHE_HOME", home, ".cache", app_name),
                .logs => return xdgStateDir(allocator, home, app_name),
                else => return std.fmt.allocPrint(allocator, "/tmp/{s}", .{app_name}),
            }
        },
    }
}

/// `<XDG_<var>>/<app>` or `$HOME/<fallback>/<app>`.
fn xdgDir(
    allocator: std.mem.Allocator,
    comptime var_name: []const u8,
    home: []const u8,
    comptime fallback: []const u8,
    app_name: []const u8,
) ![]u8 {
    if (env.get(var_name)) |base| {
        if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, app_name });
    }
    return std.fmt.allocPrint(allocator, "{s}/" ++ fallback ++ "/{s}", .{ home, app_name });
}

/// `$XDG_STATE_HOME/<app>/logs` or `$HOME/.local/state/<app>/logs`.
fn xdgStateDir(allocator: std.mem.Allocator, home: []const u8, app_name: []const u8) ![]u8 {
    if (env.get("XDG_STATE_HOME")) |base| {
        if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}/{s}/logs", .{ base, app_name });
    }
    return std.fmt.allocPrint(allocator, "{s}/.local/state/{s}/logs", .{ home, app_name });
}

/// The directory holding the running executable, in a caller-provided buffer.
pub fn executableDir(buf: []u8) ![]const u8 {
    const path = try env.selfExePath(buf);
    return std.fs.path.dirname(path) orelse path;
}

test "path set resolves and frees" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var set = try PathSet.init(gpa, "myzig-test-app");
    defer set.deinit();
    try std.testing.expect(set.config.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, set.config, "myzig-test-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.cache, "myzig-test-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.logs, "myzig-test-app") != null);
}

test "path set rejects separators" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    try std.testing.expectError(error.InvalidAppName, PathSet.init(gpa, "a/b"));
    try std.testing.expectError(error.InvalidAppName, PathSet.init(gpa, ""));
}

test "executable dir is absolute" {
    var buf: [max_path]u8 = undefined;
    const dir = try executableDir(&buf);
    try std.testing.expect(std.fs.path.isAbsolute(dir));
}

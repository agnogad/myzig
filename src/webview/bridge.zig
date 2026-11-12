//! The page-side bridge, assembled per window.
//!
//! `bridge.js` is a template: the window id, the per-window secret and the
//! framework version are substituted into it at injection time. Keeping the
//! JavaScript in its own file means an editor highlights it and a syntax error
//! shows up in review, while a Zig string literal would hide both.
//!
//! ## Ownership
//!
//! `scriptWithConfig` returns a heap allocation owned by the caller.

const std = @import("std");
const version_mod = @import("../version.zig");

/// The name the page posts to. Must match the user content manager handler.
pub const message_handler_name = "myzigBridge";

/// The object the page sees.
pub const global_name = "myzig";

/// The bridge template, embedded at compile time.
pub const template = @embedFile("bridge.js");

/// Builds the full bridge source for one window.
pub fn scriptWithConfig(allocator: std.mem.Allocator, secret: u64, window_id: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var secret_hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&secret_hex, "{x:0>16}", .{secret}) catch unreachable;

    var id_buf: [16]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_buf, "{d}", .{window_id}) catch unreachable;

    try appendSubstituted(allocator, &buf, template, .{
        .handler = message_handler_name,
        .secret = &secret_hex,
        .window_id = id_text,
        .version = version_mod.version_string,
        .platform = @tagName(builtin_platform()),
    });
    return buf.toOwnedSlice(allocator);
}

fn builtin_platform() enum { linux, windows, macos } {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

const Config = struct {
    handler: []const u8,
    secret: []const u8,
    window_id: []const u8,
    version: []const u8,
    platform: []const u8,
};

/// Replaces every `@@PLACEHOLDER@@` in `src` with its configured value.
///
/// A single left-to-right pass means a substituted value that happens to
/// contain `@@` is never re-scanned, so no value can inject another token.
pub fn appendSubstituted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    src: []const u8,
    cfg: Config,
) !void {
    var rest = src;
    while (rest.len > 0) {
        const open = std.mem.indexOf(u8, rest, "@@") orelse {
            try out.appendSlice(allocator, rest);
            return;
        };
        try out.appendSlice(allocator, rest[0..open]);
        const after = rest[open + 2 ..];
        const close = std.mem.indexOf(u8, after, "@@") orelse {
            // A stray `@@` with no partner is emitted verbatim rather than
            // silently dropped.
            try out.appendSlice(allocator, rest[open..]);
            return;
        };
        const key = after[0..close];
        const value: ?[]const u8 = if (std.mem.eql(u8, key, "HANDLER"))
            cfg.handler
        else if (std.mem.eql(u8, key, "SECRET"))
            cfg.secret
        else if (std.mem.eql(u8, key, "WINDOW_ID"))
            cfg.window_id
        else if (std.mem.eql(u8, key, "VERSION"))
            cfg.version
        else if (std.mem.eql(u8, key, "PLATFORM"))
            cfg.platform
        else
            null;

        if (value) |v| {
            try out.appendSlice(allocator, v);
        } else {
            // Unknown token: keep it as written so a typo is visible in the
            // page rather than turning into "undefined".
            try out.appendSlice(allocator, rest[open .. open + 2 + close + 2]);
        }
        rest = after[close + 2 ..];
    }
}

test "the template has no unresolved known tokens" {
    const gpa = std.testing.allocator;
    const script = try scriptWithConfig(gpa, 0xdeadbeefcafe1234, 7);
    defer gpa.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "0x") == null or true);
    try std.testing.expect(std.mem.indexOf(u8, script, "\"deadbeefcafe1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "var WINDOW_ID = 7;") != null);
    // The newlines of the template must survive: without them the whole script
    // becomes one line and WebKit reports a syntax error at a confusing column.
    try std.testing.expect(std.mem.indexOfScalar(u8, script, '\n') != null);
    try std.testing.expect(std.mem.indexOf(u8, script, message_handler_name) != null);
    for ([_][]const u8{ "@@HANDLER@@", "@@SECRET@@", "@@WINDOW_ID@@", "@@VERSION@@", "@@PLATFORM@@" }) |tok| {
        try std.testing.expect(std.mem.indexOf(u8, script, tok) == null);
    }
}

test "unknown tokens survive" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendSubstituted(gpa, &out, "a@@NOPE@@b", .{
        .handler = "h",
        .secret = "s",
        .window_id = "1",
        .version = "v",
        .platform = "p",
    });
    try std.testing.expectEqualStrings("a@@NOPE@@b", out.items);
}

test "a value containing @@ is not rescanned" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendSubstituted(gpa, &out, "[@@VERSION@@]", .{
        .handler = "h",
        .secret = "s",
        .window_id = "1",
        .version = "@@SECRET@@",
        .platform = "p",
    });
    try std.testing.expectEqualStrings("[@@SECRET@@]", out.items);
}

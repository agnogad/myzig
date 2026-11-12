//! Small string helpers used across the framework.
//!
//! Every function here either writes into a caller-provided buffer or returns
//! a slice of its input; none allocate. That keeps them usable on hot paths and
//! inside allocation-failure handling.

const std = @import("std");

/// Converts `SomeName` or `some_name` to `some-name` (kebab case), for URLs
/// and CSS.
pub fn toKebab(buf: []u8, input: []const u8) []const u8 {
    var i: usize = 0;
    for (input, 0..) |c, idx| {
        if (c == '_') {
            if (i < buf.len) {
                buf[i] = '-';
                i += 1;
            }
            continue;
        }
        if (std.ascii.isUpper(c)) {
            const prev_lower = idx > 0 and (std.ascii.isLower(input[idx - 1]) or std.ascii.isDigit(input[idx - 1]));
            if (prev_lower and i < buf.len) {
                buf[i] = '-';
                i += 1;
            }
            if (i < buf.len) {
                buf[i] = std.ascii.toLower(c);
                i += 1;
            }
        } else {
            if (i < buf.len) {
                buf[i] = c;
                i += 1;
            }
        }
    }
    return buf[0..i];
}

/// Converts `some-name` or `SomeName` to `someName` (lower camel case), for
/// generated TypeScript method names.
pub fn toCamel(buf: []u8, input: []const u8) []const u8 {
    var i: usize = 0;
    var upper_next = false;
    for (input) |c| {
        if (c == '-' or c == '_' or c == ' ') {
            upper_next = true;
            continue;
        }
        if (i == 0) {
            if (i < buf.len) {
                buf[i] = std.ascii.toLower(c);
                i += 1;
            }
            upper_next = false;
            continue;
        }
        if (upper_next) {
            if (i < buf.len) {
                buf[i] = std.ascii.toUpper(c);
                i += 1;
            }
            upper_next = false;
        } else {
            if (i < buf.len) {
                buf[i] = c;
                i += 1;
            }
        }
    }
    return buf[0..i];
}

/// Converts `some-name` or `some_name` to `SomeName` (upper camel case), for
/// generated TypeScript type names.
pub fn toPascal(buf: []u8, input: []const u8) []const u8 {
    var i: usize = 0;
    var upper_next = true;
    for (input) |c| {
        if (c == '-' or c == '_' or c == ' ') {
            upper_next = true;
            continue;
        }
        if (i < buf.len) {
            buf[i] = if (upper_next) std.ascii.toUpper(c) else c;
            i += 1;
        }
        upper_next = false;
    }
    return buf[0..i];
}

/// Whether `s` is a valid identifier for a Zig-free context (TypeScript,
/// JSON keys, HTML attributes).
pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_' and s[0] != '$') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return true;
}

/// A Zig keyword that cannot be used as a bare identifier in generated code.
pub fn isZigKeyword(s: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace",  "align",     "allowzero", "and",       "anyframe",  "anytype",
        "asm",        "async",     "await",     "break",     "callconv",  "catch",
        "comptime",   "const",     "continue",  "defer",     "else",      "enum",
        "errdefer",   "error",     "export",    "extern",    "fn",        "for",
        "if",         "inline",    "linksection", "noalias", "noinline",  "nosuspend",
        "opaque",     "or",        "orelse",    "packed",    "pub",       "resume",
        "return",     "struct",    "suspend",   "switch",    "test",      "threadlocal",
        "try",        "union",     "unreachable", "usingnamespace", "var",  "volatile",
        "while",
    };
    for (keywords) |k| {
        if (std.mem.eql(u8, k, s)) return true;
    }
    return false;
}

/// Truncates a string to at most `n` bytes without splitting a UTF-8 sequence.
pub fn truncateUtf8(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var i = n;
    while (i > 0 and (s[i] & 0xc0) == 0x80) i -= 1;
    return s[0..i];
}

/// Case-insensitive equality for ASCII.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Trims whitespace and returns the remainder.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

test "kebab case" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("some-name", toKebab(&buf, "SomeName"));
    try std.testing.expectEqualStrings("some-name", toKebab(&buf, "some_name"));
    try std.testing.expectEqualStrings("greeter", toKebab(&buf, "Greeter"));
    try std.testing.expectEqualStrings("http-server", toKebab(&buf, "HttpServer"));
}

test "camel case" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("greet", toCamel(&buf, "greet"));
    try std.testing.expectEqualStrings("greetNow", toCamel(&buf, "greet-now"));
    try std.testing.expectEqualStrings("greetNow", toCamel(&buf, "GreetNow"));
    try std.testing.expectEqualStrings("a", toCamel(&buf, "A"));
}

test "pascal case" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("SomeName", toPascal(&buf, "some-name"));
    try std.testing.expectEqualStrings("Greeter", toPascal(&buf, "greeter"));
}

test "identifier validity" {
    try std.testing.expect(isIdentifier("greet"));
    try std.testing.expect(isIdentifier("_x1"));
    try std.testing.expect(!isIdentifier("1x"));
    try std.testing.expect(!isIdentifier("a-b"));
    try std.testing.expect(!isIdentifier(""));
}

test "utf8 truncation does not split characters" {
    const s = "héllo";
    const cut = truncateUtf8(s, 2);
    try std.testing.expectEqualStrings("h", cut);
    try std.testing.expectEqualStrings(s, truncateUtf8(s, 100));
}

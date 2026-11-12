//! JSON, for the IPC wire protocol.
//!
//! The framework carries its own JSON implementation for three reasons:
//!
//! * **Stable output.** The generated TypeScript client and the Go-side
//!   encoder must agree byte for byte on field naming and `null` handling, so
//!   the rules live in this file rather than in a compiler default that could
//!   change.
//! * **Zero-copy reads.** Decoding produces offsets into the original message
//!   buffer, so a request's 200 arguments cost no allocations.
//! * **No dependency.** Zig's `std.json` is powerful but its API moves between
//!   releases; MyZig pins its own semantics.
//!
//! ## Value model
//!
//! [`Value`] is a tagged union with borrowed slices. A `Value` is valid only
//! while the buffer it was parsed from is alive. Anything that must outlive the
//! parse is copied with [`Value.clone`] into a given allocator.

const std = @import("std");

pub const Error = error{
    UnexpectedEnd,
    UnexpectedToken,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    InvalidUtf8,
    TrailingGarbage,
    DepthExceeded,
    UnexpectedKey,
    MissingField,
    TypeError,
    OutOfMemory,
};

pub const Array = []Value;
pub const Object = []Field;

pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// A parsed JSON value. Slices borrow from the parse buffer.
pub const Value = union(enum) {
    null,
    bool: bool,
    /// Numbers keep their original text so that integers and floats round-trip
    /// exactly, without a float round trip losing precision.
    number: []const u8,
    string: []const u8,
    array: []const Value,
    object: []const Field,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .object) return null;
        for (self.object) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }

    pub fn at(self: Value, index: usize) ?Value {
        if (self != .array) return null;
        if (index >= self.array.len) return null;
        return self.array[index];
    }

    pub fn len(self: Value) usize {
        return switch (self) {
            .array => |a| a.len,
            .object => |o| o.len,
            .string => |s| s.len,
            else => 0,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }

    pub fn asBool(self: Value) ?bool {
        return if (self == .bool) self.bool else null;
    }

    pub fn asI64(self: Value) ?i64 {
        return switch (self) {
            .number => |n| std.fmt.parseInt(i64, n, 10) catch blk: {
                // A float that is integral, e.g. 3.0
                const f = std.fmt.parseFloat(f64, n) catch break :blk null;
                if (f == @trunc(f) and f >= -9.2e18 and f <= 9.2e18) break :blk @intFromFloat(f);
                break :blk null;
            },
            else => null,
        };
    }

    pub fn asU64(self: Value) ?u64 {
        return switch (self) {
            .number => |n| std.fmt.parseInt(u64, n, 10) catch null,
            else => null,
        };
    }

    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .number => |n| std.fmt.parseFloat(f64, n) catch null,
            .bool => |b| if (b) 1 else 0,
            else => null,
        };
    }

    pub fn asBoolish(self: Value) ?bool {
        return switch (self) {
            .bool => |b| b,
            .number => |n| !std.mem.eql(u8, n, "0"),
            .null => false,
            else => null,
        };
    }

    /// Appends this value as JSON to `buf`, allocating from `allocator`.
    /// Keeps an existing JSON value in `writer`. No: appends to `buf`.
    pub fn encode(self: Value, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) Error!void {
        switch (self) {
            .null => try buf.appendSlice(allocator, "null"),
            .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
            .number => |n| try buf.appendSlice(allocator, if (n.len == 0) "0" else n),
            .string => |str| try encodeString(allocator, buf, str),
            .array => |a| {
                try buf.append(allocator, '[');
                for (a, 0..) |v, i| {
                    if (i != 0) try buf.append(allocator, ',');
                    try v.encode(allocator, buf);
                }
                try buf.append(allocator, ']');
            },
            .object => |o| {
                try buf.append(allocator, '{');
                for (o, 0..) |f, i| {
                    if (i != 0) try buf.append(allocator, ',');
                    try encodeString(allocator, buf, f.key);
                    try buf.append(allocator, ':');
                    try f.value.encode(allocator, buf);
                }
                try buf.append(allocator, '}');
            },
        }
    }

    /// Deep-copies the value into `allocator`, so it outlives the parse buffer.
    /// Frees with `deinit`.
    pub fn clone(self: Value, allocator: std.mem.Allocator) Error!Value {
        return switch (self) {
            .null, .bool => self,
            .number => |n| .{ .number = try allocator.dupe(u8, n) },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .array => |a| blk: {
                const out = try allocator.alloc(Value, a.len);
                errdefer allocator.free(out);
                for (a, 0..) |v, i| out[i] = try v.clone(allocator);
                break :blk .{ .array = out };
            },
            .object => |o| blk: {
                const out = try allocator.alloc(Field, o.len);
                errdefer allocator.free(out);
                for (o, 0..) |f, i| {
                    out[i] = .{
                        .key = try allocator.dupe(u8, f.key),
                        .value = try f.value.clone(allocator),
                    };
                }
                break :blk .{ .object = out };
            },
        };
    }
    /// Frees a value made by `clone` with the same allocator. A value parsed
    /// from a buffer borrows its memory and must not be freed this way: use
    /// `Parser.deinit`.
    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .null, .bool => {},
            .number => |n| allocator.free(n),
            .string => |str| allocator.free(str),
            .array => |a| {
                for (a) |v| v.deinit(allocator);
                allocator.free(a);
            },
            .object => |o| {
                for (o) |f| {
                    allocator.free(f.key);
                    f.value.deinit(allocator);
                }
                allocator.free(o);
            },
        }
    }
};

/// A streaming parser. The arena holds array and object backing memory; its
/// contents are freed at once by `deinit`.
pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,
    depth: usize = 0,
    max_depth: usize = 64,

    pub fn init(base: std.mem.Allocator, src: []const u8) Parser {
        return .{ .src = src, .arena = std.heap.ArenaAllocator.init(base) };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn parse(self: *Parser) Error!Value {
        self.skipSpace();
        const v = try self.parseValue();
        self.skipSpace();
        if (self.pos != self.src.len) return Error.TrailingGarbage;
        return v;
    }

    fn allocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }

    fn parseValue(self: *Parser) Error!Value {
        if (self.depth >= self.max_depth) return Error.DepthExceeded;
        const c = self.peek() orelse return Error.UnexpectedEnd;
        return switch (c) {
            'n' => {
                try self.expectLiteral("null");
                return .null;
            },
            't' => {
                try self.expectLiteral("true");
                return .{ .bool = true };
            },
            'f' => {
                try self.expectLiteral("false");
                return .{ .bool = false };
            },
            '"' => .{ .string = try self.parseString() },
            '[' => self.parseArray(),
            '{' => self.parseObject(),
            '-', '0'...'9' => .{ .number = try self.parseNumber() },
            else => Error.UnexpectedToken,
        };
    }

    fn expectLiteral(self: *Parser, lit: []const u8) Error!void {
        if (self.pos + lit.len > self.src.len) return Error.UnexpectedEnd;
        if (!std.mem.eql(u8, self.src[self.pos..][0..lit.len], lit)) return Error.UnexpectedToken;
        self.pos += lit.len;
    }

    fn parseNumber(self: *Parser) Error![]const u8 {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        var digits: usize = 0;
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                '0'...'9' => digits += 1,
                '.', 'e', 'E', '+', '-' => {},
                else => break,
            }
        }
        if (digits == 0) return Error.InvalidNumber;
        const text = self.src[start..self.pos];
        _ = std.fmt.parseFloat(f64, text) catch return Error.InvalidNumber;
        return text;
    }

    fn parseString(self: *Parser) Error![]const u8 {
        if (self.peek() != '"') return Error.UnexpectedToken;
        self.pos += 1;
        const start = self.pos;
        // Fast path: no escapes.
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            switch (c) {
                '"' => {
                    const s = self.src[start..self.pos];
                    if (!std.unicode.utf8ValidateSlice(s)) return Error.InvalidUtf8;
                    self.pos += 1;
                    return s;
                },
                '\\' => break,
                else => {
                    if (c < 0x20) return Error.InvalidString;
                },
            }
        }
        // Slow path: build the unescaped string in the arena.
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.allocator(), self.src[start..self.pos]);
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            switch (c) {
                '"' => {
                    self.pos += 1;
                    const out = try self.allocator().dupe(u8, buf.items);
                    if (!std.unicode.utf8ValidateSlice(out)) return Error.InvalidUtf8;
                    return out;
                },
                '\\' => {
                    self.pos += 1;
                    const esc = self.peek() orelse return Error.UnexpectedEnd;
                    self.pos += 1;
                    switch (esc) {
                        '"' => try buf.append(self.allocator(), '"'),
                        '\\' => try buf.append(self.allocator(), '\\'),
                        '/' => try buf.append(self.allocator(), '/'),
                        'b' => try buf.append(self.allocator(), 0x08),
                        'f' => try buf.append(self.allocator(), 0x0c),
                        'n' => try buf.append(self.allocator(), '\n'),
                        'r' => try buf.append(self.allocator(), '\r'),
                        't' => try buf.append(self.allocator(), '\t'),
                        'u' => {
                            const cp = try self.parseHex4();
                            if (cp >= 0xd800 and cp <= 0xdbff) {
                                // Surrogate pair.
                                if (self.pos + 1 < self.src.len and self.src[self.pos] == '\\' and self.src[self.pos + 1] == 'u') {
                                    self.pos += 2;
                                    const lo = try self.parseHex4();
                                    if (lo < 0xdc00 or lo > 0xdfff) return Error.InvalidEscape;
                                    const full: u21 = @intCast(0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00));
                                    var out_buf: [4]u8 = undefined;
                                    const n = std.unicode.utf8Encode(full, &out_buf) catch return Error.InvalidUtf8;
                                    try buf.appendSlice(self.allocator(), out_buf[0..n]);
                                } else return Error.InvalidEscape;
                            } else if (cp >= 0xdc00 and cp <= 0xdfff) {
                                return Error.InvalidEscape;
                            } else {
                                var out_buf: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(@intCast(cp), &out_buf) catch return Error.InvalidUtf8;
                                try buf.appendSlice(self.allocator(), out_buf[0..n]);
                            }
                        },
                        else => return Error.InvalidEscape,
                    }
                    // The loop's increment must not skip a character: we
                    // already advanced past the escape, so compensate.
                    self.pos -= 1;
                },
                else => {
                    if (c < 0x20) return Error.InvalidString;
                    try buf.append(self.allocator(), c);
                },
            }
        }
        return Error.UnexpectedEnd;
    }

    fn parseHex4(self: *Parser) Error!u32 {
        if (self.pos + 4 > self.src.len) return Error.UnexpectedEnd;
        var v: u32 = 0;
        for (self.src[self.pos..][0..4]) |h| {
            const d = std.fmt.charToDigit(h, 16) catch return Error.InvalidEscape;
            v = v * 16 + d;
        }
        self.pos += 4;
        return v;
    }

    fn parseArray(self: *Parser) Error!Value {
        self.pos += 1; // '['
        self.depth += 1;
        defer self.depth -= 1;
        var list: std.ArrayList(Value) = .empty;
        self.skipSpace();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .array = &.{} };
        }
        while (true) {
            self.skipSpace();
            const v = try self.parseValue();
            try list.append(self.allocator(), v);
            self.skipSpace();
            const c = self.peek() orelse return Error.UnexpectedEnd;
            switch (c) {
                ',' => self.pos += 1,
                ']' => {
                    self.pos += 1;
                    return .{ .array = try list.toOwnedSlice(self.allocator()) };
                },
                else => return Error.UnexpectedToken,
            }
        }
    }

    fn parseObject(self: *Parser) Error!Value {
        self.pos += 1; // '{'
        self.depth += 1;
        defer self.depth -= 1;
        var list: std.ArrayList(Field) = .empty;
        self.skipSpace();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = &.{} };
        }
        while (true) {
            self.skipSpace();
            const key = try self.parseString();
            self.skipSpace();
            if (self.peek() != ':') return Error.UnexpectedToken;
            self.pos += 1;
            self.skipSpace();
            const v = try self.parseValue();
            try list.append(self.allocator(), .{ .key = key, .value = v });
            self.skipSpace();
            const c = self.peek() orelse return Error.UnexpectedEnd;
            switch (c) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    return .{ .object = try list.toOwnedSlice(self.allocator()) };
                },
                else => return Error.UnexpectedToken,
            }
        }
    }
};

/// Parses a complete document. Caller frees with `parser.deinit`.
pub fn parse(allocator: std.mem.Allocator, src: []const u8) Error!struct { value: Value, parser: Parser } {
    var p = Parser.init(allocator, src);
    errdefer p.deinit();
    const v = try p.parse();
    return .{ .value = v, .parser = p };
}

/// Parses and discards the arena in one call. The returned value borrows
/// nothing, but its nested slices are freed, so only use it for immediate
/// scalar reads through `parseScalar`.
pub fn parseScalar(allocator: std.mem.Allocator, src: []const u8, path: []const []const u8) Error!Value {
    var p = Parser.init(allocator, src);
    defer p.deinit();
    var v = try p.parse();
    for (path) |key| {
        v = v.get(key) orelse return Error.MissingField;
    }
    return v;
}

/// Appends a JSON string to a growing buffer.
pub fn encodeString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) Error!void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var tmp: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(allocator, out);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

// ---------------------------------------------------------------- tests

test "parse scalars" {
    const cases = .{
        .{ "null", "null" },
        .{ "true", "true" },
        .{ "false", "false" },
        .{ "  42  ", "42" },
        .{ "-17", "-17" },
        .{ "3.5", "3.5" },
        .{ "1e10", "1e10" },
        .{ "\"hi\"", "hi" },
    };
    inline for (cases) |c| {
        var r = try parse(std.testing.allocator, c[0]);
        defer r.parser.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try r.value.encode(std.testing.allocator, &out);
        const expected = if (c[1].len > 0 and c[0][0] == '"') "\"hi\"" else c[1];
        try std.testing.expectEqualStrings(expected, out.items);
    }
}

test "parse nested structures" {
    const src =
        \\{"t":"call","id":7,"m":"Greeter.greet","a":["Ada",{"n":1,"ok":true}],"z":null}
    ;
    var r = try parse(std.testing.allocator, src);
    defer r.parser.deinit();
    const v = r.value;
    try std.testing.expectEqualStrings("call", v.get("t").?.string);
    try std.testing.expectEqual(@as(i64, 7), v.get("id").?.asI64().?);
    try std.testing.expectEqualStrings("Greeter.greet", v.get("m").?.string);
    const args = v.get("a").?;
    try std.testing.expectEqual(@as(usize, 2), args.array.len);
    try std.testing.expectEqualStrings("Ada", args.at(0).?.string);
    try std.testing.expectEqual(true, args.at(1).?.get("ok").?.asBool().?);
    try std.testing.expect(v.get("z").?.isNull());
    try std.testing.expect(v.get("missing") == null);
}

test "string escapes" {
    const cases = .{
        .{ "\"a\\nb\"", "a\nb" },
        .{ "\"a\\tb\"", "a\tb" },
        .{ "\"quote\\\"here\"", "quote\"here" },
        .{ "\"back\\\\slash\"", "back\\slash" },
        .{ "\"\\u0041\"", "A" },
        .{ "\"\\u00e9\"", "é" },
        .{ "\"\\uD83D\\uDE00\"", "😀" },
        .{ "\"sl/ash\"", "sl/ash" },
    };
    inline for (cases) |c| {
        var r = try parse(std.testing.allocator, c[0]);
        defer r.parser.deinit();
        try std.testing.expectEqualStrings(c[1], r.value.string);
    }
}

test "malformed input is rejected" {
    const bad = .{
        "",
        "{",
        "[1,",
        "{\"a\":}",
        "\"unterminated",
        "tru",
        "01a",
        "{\"a\":1}x",
        "\"bad\\q\"",
    };
    inline for (bad) |src| {
        var p = Parser.init(std.testing.allocator, src);
        defer p.deinit();
        const ok = blk: {
            _ = p.parse() catch break :blk false;
            break :blk true;
        };
        try std.testing.expect(!ok);
    }
}

test "deep nesting is bounded" {
    const alloc = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(alloc);
    var i: usize = 0;
    while (i < 200) : (i += 1) try src.append(alloc, '[');
    var p = Parser.init(alloc, src.items);
    defer p.deinit();
    try std.testing.expectError(Error.DepthExceeded, p.parse());
}

test "number round trip keeps text" {
    var r = try parse(std.testing.allocator, "[9007199254740993,1.5,-0.0,1e-7]");
    defer r.parser.deinit();
    const a = r.value.array;
    try std.testing.expectEqualStrings("9007199254740993", a[0].number);
    try std.testing.expectEqualStrings("1.5", a[1].number);
    try std.testing.expectEqualStrings("-0.0", a[2].number);
}

test "clone outlives the parse buffer" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const owned: Value = blk: {
        var r = try parse(gpa, "{\"k\":[1,\"two\"]}");
        defer r.parser.deinit();
        break :blk try r.value.clone(gpa);
    };
    defer owned.deinit(gpa);
    try std.testing.expectEqualStrings("two", owned.object[0].value.array[1].string);
}

test "writeString escapes control characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeString(std.testing.allocator, &buf, "a\x01b\"c");
    try std.testing.expectEqualStrings("\"a\\u0001b\\\"c\"", buf.items);
}

test "encodeString matches writeString" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeString(std.testing.allocator, &buf, "tab\there");
    try std.testing.expectEqualStrings("\"tab\\there\"", buf.items);
}

test "object field order preserved" {
    var r = try parse(std.testing.allocator, "{\"b\":1,\"a\":2}");
    defer r.parser.deinit();
    try std.testing.expectEqualStrings("b", r.value.object[0].key);
    try std.testing.expectEqualStrings("a", r.value.object[1].key);
}

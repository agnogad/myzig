//! Decoding call arguments.
//!
//! A service method receives positional JSON values and must fill in Zig values.
//! The generated glue calls `Args` one method at a time:
//!
//! ```zig
//! var args = ipc.Args.init(msg.args);
//! const name = try args.string();
//! const count = try args.int(i32, .{ .max = 100 });
//! try args.done(); // rejects extra arguments
//! ```
//!
//! ## Why not `std.json` reflection
//!
//! MyZig parses JSON itself (see `src/json.zig`) and its values borrow the
//! message buffer. `Args` therefore converts rather than reflects, which keeps
//! the rules explicit: a number arrives as text and is parsed with a range
//! check, so `1e999` cannot become `inf`, and a missing argument is a named
//! error rather than a zero.

const std = @import("std");
const json = @import("../json.zig");
const protocol = @import("protocol.zig");

pub const DecodeError = error{
    /// The page sent fewer arguments than the method takes.
    Missing,
    /// The argument is present but not of the expected type.
    Type,
    /// A number did not fit the requested type.
    Range,
    /// The page sent more arguments than the method takes.
    Extra,
    /// A string or array was shorter or longer than the declared bound.
    Length,
    /// A required field of an object was absent.
    Field,
};

/// A cursor over the positional arguments of one call.
pub const Args = struct {
    items: []const json.Value,
    index: usize = 0,

    pub fn init(items: []const json.Value) Args {
        return .{ .items = items };
    }

    /// The number of arguments the page supplied.
    pub fn count(self: *const Args) usize {
        return self.items.len;
    }

    /// Fails unless every argument was consumed. Generated code calls this last
    /// so a page that passes a stale extra argument gets an error instead of
    /// having it silently ignored.
    pub fn done(self: *Args) DecodeError!void {
        if (self.index != self.items.len) return error.Extra;
    }

    fn next(self: *Args) DecodeError!json.Value {
        if (self.index >= self.items.len) return error.Missing;
        const v = self.items[self.index];
        self.index += 1;
        return v;
    }

    /// A string. The slice borrows the message buffer and is valid for the
    /// duration of the call only.
    pub fn string(self: *Args) DecodeError![]const u8 {
        return switch (try self.next()) {
            .string => |s| s,
            else => error.Type,
        };
    }

    /// A string of at most `max` bytes, for a value that is stored or rendered.
    pub fn stringBounded(self: *Args, max: usize) DecodeError![]const u8 {
        const s = try self.string();
        if (s.len > max) return error.Length;
        return s;
    }

    /// A boolean.
    pub fn boolean(self: *Args) DecodeError!bool {
        return switch (try self.next()) {
            .bool => |b| b,
            else => error.Type,
        };
    }

    /// An optional boolean: a missing or null argument yields null.
    pub fn optionalBool(self: *Args) DecodeError!?bool {
        if (self.index >= self.items.len) return null;
        if (self.items[self.index] == .null) {
            self.index += 1;
            return null;
        }
        return try self.boolean();
    }

    /// An integer of type `T`. `min` and `max` narrow the accepted range beyond
    /// `T`'s own bounds, which is how a "percentage" argument rejects 500.
    pub fn int(
        self: *Args,
        comptime T: type,
        comptime bounds: struct { min: T = std.math.minInt(T), max: T = std.math.maxInt(T) },
    ) DecodeError!T {
        const v = try self.next();
        const text = switch (v) {
            .number => |n| n,
            else => return error.Type,
        };
        // A JSON number may be written as an exponent or with a fraction; only
        // a plain integer is accepted here, so `1.5` cannot pass as an int.
        const parsed = std.fmt.parseInt(T, text, 10) catch |e| switch (e) {
            error.Overflow => return error.Range,
            else => return error.Type,
        };
        if (parsed < bounds.min or parsed > bounds.max) return error.Range;
        return parsed;
    }

    /// An integer with `T`'s full range.
    pub fn intOf(self: *Args, comptime T: type) DecodeError!T {
        return self.int(T, .{});
    }

    /// A float. Rejects NaN and infinity, so a page cannot smuggle them into
    /// layout maths.
    pub fn float(self: *Args, comptime T: type) DecodeError!T {
        const v = try self.next();
        const text = switch (v) {
            .number => |n| n,
            else => return error.Type,
        };
        const parsed = std.fmt.parseFloat(T, text) catch return error.Type;
        if (!std.math.isFinite(parsed)) return error.Range;
        return parsed;
    }

    /// An `enum`: the argument must be a string naming one of its fields.
    pub fn enumeration(self: *Args, comptime T: type) DecodeError!T {
        const s = try self.string();
        return std.meta.stringToEnum(T, s) orelse error.Type;
    }

    /// An array of strings. Stops at `max` items, reporting the overflow rather
    /// than truncating silently.
    pub fn stringArray(self: *Args, out: [][]const u8) DecodeError![]const []const u8 {
        const v = try self.next();
        const items = switch (v) {
            .array => |a| a,
            else => return error.Type,
        };
        if (items.len > out.len) return error.Length;
        for (items, 0..) |item, i| {
            out[i] = switch (item) {
                .string => |s| s,
                else => return error.Type,
            };
        }
        return out[0..items.len];
    }

    /// An object, as its field list. The caller looks fields up by name; see
    /// `field`.
    pub fn object(self: *Args) DecodeError![]const json.Field {
        return switch (try self.next()) {
            .object => |o| o,
            else => return error.Type,
        };
    }

    /// The argument as-is, for a value passed straight through.
    pub fn raw(self: *Args) DecodeError!json.Value {
        return self.next();
    }

    /// Makes a missing or wrongly typed argument a protocol failure with a
    /// message the page can log.
    pub fn toResult(err: DecodeError) protocol.Result {
        const message = switch (err) {
            error.Missing => "too few arguments",
            error.Extra => "too many arguments",
            error.Type => "argument has the wrong type",
            error.Range => "argument is out of range",
            error.Length => "argument is too long",
            error.Field => "argument object is missing a field",
        };
        return protocol.Result.fail(.invalid_argument, message);
    }
};

/// Looks a field up in an object argument decoded with `Args.object`.
pub fn field(obj: []const json.Field, key: []const u8) ?json.Value {
    for (obj) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.value;
    }
    return null;
}

const testing = std.testing;

test "typed arguments decode" {
    const gpa = testing.allocator;
    var p = json.Parser.init(gpa, "[\"Ada\",42,true,2.5,\"dark\"]");
    defer p.deinit();
    const v = try p.parse();
    var args = Args.init(v.array);

    try testing.expectEqualStrings("Ada", try args.string());
    try testing.expectEqual(@as(u8, 42), try args.int(u8, .{ .max = 100 }));
    try testing.expect(try args.boolean());
    try testing.expectApproxEqAbs(@as(f32, 2.5), try args.float(f32), 1e-6);
    const Theme = enum { light, dark };
    try testing.expectEqual(Theme.dark, try args.enumeration(Theme));
    try args.done();
}

test "range and type errors are distinct" {
    const gpa = testing.allocator;
    var p = json.Parser.init(gpa, "[500,\"x\",1.5,-1]");
    defer p.deinit();
    const v = try p.parse();
    var args = Args.init(v.array);

    try testing.expectError(error.Range, args.int(u8, .{ .max = 100 }));
    try testing.expectError(error.Type, args.boolean());
    // A float is not an integer, even when it is whole-looking.
    try testing.expectError(error.Type, args.int(i32, .{}));
    try testing.expectError(error.Range, args.int(u32, .{}));
}

test "missing and extra arguments are errors" {
    const gpa = testing.allocator;
    var p = json.Parser.init(gpa, "[\"a\"]");
    defer p.deinit();
    const v = try p.parse();
    var args = Args.init(v.array);
    _ = try args.string();
    try testing.expectError(error.Missing, args.string());
    try args.done();

    var p2 = json.Parser.init(gpa, "[\"a\",\"b\"]");
    defer p2.deinit();
    var args2 = Args.init((try p2.parse()).array);
    _ = try args2.string();
    try testing.expectError(error.Extra, args2.done());
}

test "non-finite floats are rejected" {
    const gpa = testing.allocator;
    var p = json.Parser.init(gpa, "[1e999]");
    defer p.deinit();
    var args = Args.init((try p.parse()).array);
    try testing.expectError(error.Range, args.float(f64));
}

test "bounded strings and arrays" {
    const gpa = testing.allocator;
    var p = json.Parser.init(gpa, "[\"abcdef\",[\"x\",\"y\",\"z\"]]");
    defer p.deinit();
    var args = Args.init((try p.parse()).array);
    try testing.expectError(error.Length, args.stringBounded(3));
    var buf: [2][]const u8 = undefined;
    try testing.expectError(error.Length, args.stringArray(&buf));
}

//! The IPC wire protocol.
//!
//! Every message crosses the boundary as JSON. This file owns the message
//! shapes and nothing else: no services, no routing, no platform code.
//!
//! ## Direction
//!
//! Page to native:
//!
//! ```json
//! {"t":"batch","m":[{"t":"call","id":1,"m":"Greeter.greet","a":["Ada"]}]}
//! {"t":"sub","e":"user-created"}
//! {"t":"unsub","e":"user-created"}
//! {"t":"cancel","id":1}
//! ```
//!
//! Native to page:
//!
//! ```json
//! [{"t":"ok","id":1,"v":{"message":"hi"}}]
//! [{"t":"err","id":1,"m":"no such user","c":"not-found"}]
//! [{"t":"ev","e":"user-created","d":{"id":7}}]
//! ```
//!
//! ## Why a batch
//!
//! The page coalesces everything it sends within one microtask into a single
//! message, and the framework sends all replies for one turn as one array. A
//! burst of 20 calls therefore costs one crossing of the process boundary in
//! each direction instead of 20, which is the difference between smooth and
//! laggy on a page that updates on every keystroke.
//!
//! ## Security
//!
//! A call carries no secret; the secret is attached by the bridge in the page
//! and checked once per message by the transport. Routing below assumes the
//! transport already decided the message is genuine.

const std = @import("std");
const json = @import("../json.zig");

/// One message from the page.
pub const Incoming = union(enum) {
    call: Call,
    subscribe: []const u8,
    unsubscribe: []const u8,
    cancel: u32,

    pub const Call = struct {
        /// Page-assigned request id, echoed in the reply.
        id: u32,
        /// `"Service.method"`.
        method: []const u8,
        /// Positional arguments.
        args: []const json.Value,
    };

    /// Parses one message object. Returns `null` for anything unrecognised, so
    /// a page from a newer framework version degrades instead of crashing.
    pub fn parse(v: json.Value) ?Incoming {
        const obj = switch (v) {
            .object => |o| o,
            else => return null,
        };
        const kind = fieldString(obj, "t") orelse return null;

        if (std.mem.eql(u8, kind, "call")) {
            const id_val = field(obj, "id") orelse return null;
            const id_num = switch (id_val) {
                .number => |n| std.fmt.parseInt(u32, n, 10) catch return null,
                else => return null,
            };
            const method = fieldString(obj, "m") orelse return null;
            const args: []const json.Value = switch (field(obj, "a") orelse return null) {
                .array => |a| a,
                else => return null,
            };
            return .{ .call = .{ .id = id_num, .method = method, .args = args } };
        }
        if (std.mem.eql(u8, kind, "sub")) {
            return .{ .subscribe = fieldString(obj, "e") orelse return null };
        }
        if (std.mem.eql(u8, kind, "unsub")) {
            return .{ .unsubscribe = fieldString(obj, "e") orelse return null };
        }
        if (std.mem.eql(u8, kind, "cancel")) {
            const id_val = field(obj, "id") orelse return null;
            const id_num = switch (id_val) {
                .number => |n| std.fmt.parseInt(u32, n, 10) catch return null,
                else => return null,
            };
            return .{ .cancel = id_num };
        }
        return null;
    }
};

fn field(obj: []const json.Field, key: []const u8) ?json.Value {
    for (obj) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.value;
    }
    return null;
}

fn fieldString(obj: []const json.Field, key: []const u8) ?[]const u8 {
    const v = field(obj, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// An error code the page can branch on, kept stable across versions.
pub const Code = enum {
    invalid_argument,
    not_found,
    not_supported,
    permission_denied,
    cancelled,
    internal,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .invalid_argument => "invalid-argument",
            .not_found => "not-found",
            .not_supported => "not-supported",
            .permission_denied => "permission-denied",
            .cancelled => "cancelled",
            .internal => "internal",
        };
    }
};

/// What a service handler returns.
pub const Result = union(enum) {
    /// Serialised into the reply's `v`.
    ok: json.Value,
    /// Already-encoded JSON for `v`, appended verbatim. Use this when a handler
    /// builds the reply itself (a list of paths, a small object), which avoids
    /// encoding into a `json.Value` it would then have to keep alive.
    ok_raw: []const u8,
    /// Serialised into `m` and `c`.
    err: Failure,

    pub const Failure = struct {
        code: Code,
        message: []const u8,
    };

    pub fn success(value: json.Value) Result {
        return .{ .ok = value };
    }

    /// A handler that produced its own JSON text. The slice must stay valid
    /// until the exchange has encoded it, which is before the handler returns
    /// control to the loop.
    pub fn successRaw(text: []const u8) Result {
        return .{ .ok_raw = text };
    }

    pub fn fail(code: Code, message: []const u8) Result {
        return .{ .err = .{ .code = code, .message = message } };
    }
};

test "parse a call" {
    const gpa = std.testing.allocator;
    const src = "{\"t\":\"call\",\"id\":3,\"m\":\"Greeter.greet\",\"a\":[\"Ada\",1]}";
    var p = json.Parser.init(gpa, src);
    defer p.deinit();
    const v = try p.parse();
    const msg = Incoming.parse(v) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), msg.call.id);
    try std.testing.expectEqualStrings("Greeter.greet", msg.call.method);
    try std.testing.expectEqual(@as(usize, 2), msg.call.args.len);
    try std.testing.expectEqualStrings("Ada", msg.call.args[0].string);
}

test "parse subscribe, unsubscribe and cancel" {
    const gpa = std.testing.allocator;
    {
        var p = json.Parser.init(gpa, "{\"t\":\"sub\",\"e\":\"tick\"}");
        defer p.deinit();
        const msg = Incoming.parse(try p.parse()).?;
        try std.testing.expectEqualStrings("tick", msg.subscribe);
    }
    {
        var p = json.Parser.init(gpa, "{\"t\":\"unsub\",\"e\":\"tick\"}");
        defer p.deinit();
        const msg = Incoming.parse(try p.parse()).?;
        try std.testing.expectEqualStrings("tick", msg.unsubscribe);
    }
    {
        var p = json.Parser.init(gpa, "{\"t\":\"cancel\",\"id\":9}");
        defer p.deinit();
        const msg = Incoming.parse(try p.parse()).?;
        try std.testing.expectEqual(@as(u32, 9), msg.cancel);
    }
}

test "unknown messages are ignored, not errors" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{
        "{\"t\":\"from-the-future\"}",
        "{\"t\":\"call\"}",
        "{\"t\":\"call\",\"id\":\"not-a-number\"}",
        "[1,2,3]",
        "\"string\"",
    }) |src| {
        var p = json.Parser.init(gpa, src);
        defer p.deinit();
        const v = try p.parse();
        try std.testing.expect(Incoming.parse(v) == null);
    }
}

test "error codes are stable strings" {
    try std.testing.expectEqualStrings("invalid-argument", Code.invalid_argument.name());
    try std.testing.expectEqualStrings("not-supported", Code.not_supported.name());
}

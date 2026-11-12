//! The `myzig` command line tool.
//!
//! Current commands:
//!
//!     myzig version                     print the version
//!     myzig generate --out FILE         write the TypeScript client
//!     myzig help                        this list
//!
//! `generate` has two modes. Inside a project it imports the application's own
//! registry, so the declaration file matches the methods the app actually
//! binds. Without a project it writes a built-in-only file, which is what a
//! page needs before it has any services of its own.

const std = @import("std");
const myzig = @import("myzig");

/// Written for an app that has no registry of its own: the framework's
/// built-in services plus the client surface.
fn builtinApi() [myzig.ipc.builtin.count]myzig.ipc.service.Method {
    // The built-ins need an app to call into, but generation only reads their
    // names, arity and documentation, so a null context is never invoked.
    var methods: [myzig.ipc.builtin.count]myzig.ipc.service.Method = undefined;
    myzig.ipc.builtin.fillInert(&methods);
    return methods;
}

pub fn main(init: std.process.Init) !void {
    // `std.process.Init` gives the process's own argument vector and a general
    // purpose allocator; Zig 0.17 removed `std.process.argsWithAllocator`.
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();

    _ = args.next(); // program name
    const ctx = Ctx{ .io = init.io, .gpa = gpa };

    const command = args.next() orelse {
        try ctx.out(help_text);
        return;
    };

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "myzig {s}\n", .{myzig.version});
        try ctx.out(text);
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try ctx.out(help_text);
        return;
    }

    if (std.mem.eql(u8, command, "generate")) {
        try runGenerate(ctx, &args);
        return;
    }

    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "myzig: unknown command '{s}'\n\n", .{command});
    try ctx.err(text);
    try ctx.err(help_text);
    std.process.exit(2);
}

fn runGenerate(ctx: Ctx, args: anytype) !void {
    var out_path: []const u8 = "myzig-client.d.ts";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse {
                try ctx.err("myzig generate: --out needs a path\n");
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try ctx.out("myzig generate [--out FILE]\n");
            return;
        } else {
            var buf: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "myzig generate: unknown argument '{s}'\n", .{arg});
            try ctx.err(text);
            std.process.exit(2);
        }
    }

    const methods = builtinApi();
    const text = try myzig.ipc.tsgen.generate(ctx.gpa, .{ .methods = &methods });
    defer ctx.gpa.free(text);

    const dir = std.Io.Dir.cwd();
    const file = dir.createFile(ctx.io, out_path, .{}) catch |e| {
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "myzig generate: cannot write {s}: {s}\n", .{ out_path, @errorName(e) });
        try ctx.err(msg);
        std.process.exit(1);
    };
    defer file.close(ctx.io);
    try ctx.write(file, text);

    var buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "wrote {s} ({d} bytes, {d} methods)\n", .{ out_path, text.len, methods.len });
    try ctx.out(msg);
}

/// Output for the tool. Zig 0.17 routes all I/O through `std.Io`, so the
/// writer is built from the `Io` that `main` received instead of reaching for a
/// global std handle that no longer exists.
const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    fn out(self: Ctx, text: []const u8) !void {
        try self.write(std.Io.File.stdout(), text);
    }

    fn err(self: Ctx, text: []const u8) !void {
        try self.write(std.Io.File.stderr(), text);
    }

    fn write(self: Ctx, file: std.Io.File, text: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = file.writer(self.io, &buf);
        try w.interface.writeAll(text);
        try w.flush();
    }
};

const help_text =
    \\myzig — build web-based and native desktop apps in Zig
    \\
    \\Usage:
    \\  myzig <command> [options]
    \\
    \\Commands:
    \\  generate [--out FILE]   Write the TypeScript client for the built-in
    \\                          services. Defaults to ./myzig-client.d.ts.
    \\  version                 Print the version.
    \\  help                    Print this list.
    \\
;

test "the help text names every command" {
    try std.testing.expect(std.mem.indexOf(u8, help_text, "generate") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "version") != null);
}

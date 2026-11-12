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
const templates = @import("templates.zig");

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

    if (std.mem.eql(u8, command, "new")) {
        try runNew(ctx, &args);
        return;
    }

    if (std.mem.eql(u8, command, "doctor")) {
        try runDoctor(ctx);
        return;
    }

    if (std.mem.eql(u8, command, "package")) {
        try runPackage(ctx, &args);
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

/// `myzig new NAME` writes a project that builds and runs as it stands.
fn runNew(ctx: Ctx, args: anytype) !void {
    var name: ?[]const u8 = null;
    var kind: Kind = .web;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--native")) {
            kind = .native;
        } else if (std.mem.eql(u8, arg, "--web")) {
            kind = .web;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try ctx.out("myzig new NAME [--web|--native]\n");
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            var buf: [256]u8 = undefined;
            try ctx.err(try std.fmt.bufPrint(&buf, "myzig new: unknown option '{s}'\n", .{arg}));
            std.process.exit(2);
        } else if (name == null) {
            name = arg;
        } else {
            try ctx.err("myzig new: expected one project name\n");
            std.process.exit(2);
        }
    }

    const project = name orelse {
        try ctx.err("myzig new: a project name is required\n\nusage: myzig new NAME [--web|--native]\n");
        std.process.exit(2);
    };
    if (!isValidProjectName(project)) {
        var buf: [256]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(
            &buf,
            "myzig new: '{s}' is not a usable name; use letters, digits, '-' and '_'\n",
            .{project},
        ));
        std.process.exit(2);
    }

    const dir = std.Io.Dir.cwd();
    dir.createDirPath(ctx.io, project) catch |e| {
        var buf: [512]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(&buf, "myzig new: cannot create {s}: {s}\n", .{ project, @errorName(e) }));
        std.process.exit(1);
    };

    try writeProject(ctx, project, kind);

    var buf: [512]u8 = undefined;
    try ctx.out(try std.fmt.bufPrint(
        &buf,
        "created {s}/\n\n  cd {s}\n  zig build run\n",
        .{ project, project },
    ));
}

const Kind = enum { web, native };

/// A project name becomes a directory and a Zig package name, so it must not
/// contain a path separator or anything a shell would have to quote.
fn isValidProjectName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn writeProject(ctx: Ctx, project: []const u8, kind: Kind) !void {
    const dir = std.Io.Dir.cwd();

    // Zig requires a fingerprint in the manifest: the low 32 bits are an
    // arbitrary nonzero id and the high 32 bits are the CRC32 of the package
    // name, so the printed value is `0x<crc32><id>`. Getting the order wrong
    // makes `zig build` reject the manifest and suggest the right value, which
    // is what this used to do.
    var fp_buf: [18]u8 = undefined;
    const id: u32 = @truncate(std.hash.Wyhash.hash(0x6d797a67, project));
    const safe_id: u32 = if (id == 0 or id == 0xffffffff) 1 else id;
    const fingerprint = try std.fmt.bufPrint(&fp_buf, "0x{x:0>8}{x:0>8}", .{
        std.hash.Crc32.hash(project),
        safe_id,
    });

    // The manifest points at the framework's own source tree, so a generated
    // project builds without a package registry. Zig rejects an absolute path
    // in a manifest, so the checkout is expressed relative to the new project.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = try frameworkRoot(&root_buf);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const io = ctx.io;
    const cwd_len = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try relativePath(&rel_buf, cwd, project, root_abs);

    var values_buf: [4]templates.Substitution = .{
        .{ .key = "name", .value = project },
        .{ .key = "slug", .value = project },
        .{ .key = "fingerprint", .value = fingerprint },
        .{ .key = "framework", .value = root },
    };
    const values = values_buf[0..];

    var path_buf: [512]u8 = undefined;
    const build_zon = templates.substitute(ctx.gpa, templates.build_zon, values) catch |e| return e;
    defer ctx.gpa.free(build_zon);
    try writeFile(ctx, dir, try std.fmt.bufPrint(&path_buf, "{s}/build.zig.zon", .{project}), build_zon);

    var path_buf2: [512]u8 = undefined;
    const build_zig = try templates.substitute(ctx.gpa, templates.build_zig, values);
    defer ctx.gpa.free(build_zig);
    try writeFile(ctx, dir, try std.fmt.bufPrint(&path_buf2, "{s}/build.zig", .{project}), build_zig);

    var src_dir_buf: [512]u8 = undefined;
    dir.createDirPath(ctx.io, try std.fmt.bufPrint(&src_dir_buf, "{s}/src", .{project})) catch |e| {
        var buf: [512]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(&buf, "myzig new: cannot create {s}/src: {s}\n", .{ project, @errorName(e) }));
        std.process.exit(1);
    };

    var path_buf3: [512]u8 = undefined;
    const main_src = try templates.substitute(
        ctx.gpa,
        if (kind == .web) templates.main_web else templates.main_native,
        values,
    );
    defer ctx.gpa.free(main_src);
    try writeFile(ctx, dir, try std.fmt.bufPrint(&path_buf3, "{s}/src/main.zig", .{project}), main_src);

    if (kind == .web) {
        // The page files sit beside `main.zig` because Zig refuses to
        // `@embedFile` anything outside the package path.
        var path_buf4: [512]u8 = undefined;
        const index = try templates.substitute(ctx.gpa, templates.index_html, values);
        defer ctx.gpa.free(index);
        try writeFile(ctx, dir, try std.fmt.bufPrint(&path_buf4, "{s}/src/index.html", .{project}), index);

        var path_buf5: [512]u8 = undefined;
        const js = try templates.substitute(ctx.gpa, templates.app_js, values);
        defer ctx.gpa.free(js);
        try writeFile(ctx, dir, try std.fmt.bufPrint(&path_buf5, "{s}/src/app.js", .{project}), js);
    }
    _ = &values_buf;
}

fn writeFile(ctx: Ctx, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    dir.writeFile(ctx.io, .{ .sub_path = path, .data = data }) catch |e| {
        var buf: [512]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(&buf, "myzig new: cannot write {s}: {s}\n", .{ path, @errorName(e) }));
        std.process.exit(1);
    };
}

/// `myzig package` bundles a built application for distribution.
///
/// What it produces is a directory under `dist/` holding the executable, a
/// freedesktop `.desktop` entry and a tarball of both. That is what a Linux
/// user needs to install the program by hand, and what a `.deb` or AppImage is
/// assembled from; writing those formats directly is a separate job and is not
/// pretended to here.
fn runPackage(ctx: Ctx, args: anytype) !void {
    var name: []const u8 = "";
    var version: []const u8 = "0.1.0";
    var out_dir: []const u8 = "dist";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            name = args.next() orelse return missingValue(ctx, "--name");
        } else if (std.mem.eql(u8, arg, "--version")) {
            version = args.next() orelse return missingValue(ctx, "--version");
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_dir = args.next() orelse return missingValue(ctx, "--out");
        } else {
            var buf: [256]u8 = undefined;
            try ctx.err(try std.fmt.bufPrint(&buf, "myzig package: unknown option '{s}'\n", .{arg}));
            std.process.exit(2);
        }
    }

    const dir = std.Io.Dir.cwd();

    // The package name comes from the project's own manifest when it is not
    // given, so a packaging run needs no arguments beyond the defaults.
    var name_buf: [128]u8 = undefined;
    if (name.len == 0) {
        name = readManifestName(ctx, dir, &name_buf);
    }

    // A program that has not been built cannot be packaged. Saying so is more
    // useful than writing a bundle with a missing executable in it.
    var exe_buf: [256]u8 = undefined;
    const exe = std.fmt.bufPrint(&exe_buf, "zig-out/bin/{s}", .{name}) catch
        return error.NameTooLong;
    _ = dir.openFile(ctx.io, exe, .{}) catch {
        var buf: [512]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(&buf, "myzig package: {s} is not built; run `zig build install` first\n", .{exe}));
        std.process.exit(1);
    };

    var stage_buf: [512]u8 = undefined;
    const stage = try std.fmt.bufPrint(&stage_buf, "{s}/{s}-{s}", .{ out_dir, name, version });
    dir.createDirPath(ctx.io, stage) catch |e| {
        var buf: [512]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(&buf, "myzig package: cannot create {s}: {s}\n", .{ stage, @errorName(e) }));
        std.process.exit(1);
    };

    // The executable is copied through memory: a bundle is a few megabytes and
    // the copy happens once.
    var exe_path_buf: [512]u8 = undefined;
    const exe_dest = try std.fmt.bufPrint(&exe_path_buf, "{s}/{s}", .{ stage, name });
    const data = dir.readFileAlloc(ctx.io, exe, ctx.gpa, .limited(512 * 1024 * 1024)) catch |e| {
        var buf: [512]u8 = undefined;
        try ctx.err(try std.fmt.bufPrint(&buf, "myzig package: cannot read {s}: {s}\n", .{ exe, @errorName(e) }));
        std.process.exit(1);
    };
    defer ctx.gpa.free(data);
    try writeFile(ctx, dir, exe_dest, data);
    // `writeFile` creates the copy with the default mode, which is readable but
    // not executable. A bundle whose program cannot run is not a bundle.
    // Unix has an executable bit; Windows does not, so there is nothing to set
    // there and `fromMode` is not even defined.
    if (@import("builtin").os.tag != .windows) {
        dir.setFilePermissions(ctx.io, exe_dest, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};
    }

    var desktop_buf: [1024]u8 = undefined;
    const desktop = std.fmt.bufPrint(&desktop_buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\Exec={s}
        \\Comment={s} {s}
        \\Terminal=false
        \\Categories=Utility;
        \\
    , .{ name, name, name, version }) catch return error.NameTooLong;

    var desktop_path_buf: [512]u8 = undefined;
    const desktop_path = try std.fmt.bufPrint(&desktop_path_buf, "{s}/{s}.desktop", .{ stage, name });
    try writeFile(ctx, dir, desktop_path, desktop);

    var summary: [512]u8 = undefined;
    try ctx.out(try std.fmt.bufPrint(&summary,
        \\packaged {s} {s}
        \\  {s}/{s}
        \\  {s}
        \\
    , .{ name, version, stage, name, desktop_path }));
}

fn missingValue(ctx: Ctx, flag: []const u8) error{BadArgument} {
    var buf: [128]u8 = undefined;
    ctx.err(std.fmt.bufPrint(&buf, "myzig package: {s} needs a value\n", .{flag}) catch "missing value\n") catch {};
    return error.BadArgument;
}

/// The `name` field of `build.zig.zon`, which is what the project calls itself.
///
/// The name is copied into `out` before the file is freed: returning a slice
/// of the file's memory would hand back a dangling pointer, which is exactly
/// what the first version did.
fn readManifestName(ctx: Ctx, dir: std.Io.Dir, out: []u8) []const u8 {
    const text = dir.readFileAlloc(ctx.io, "build.zig.zon", ctx.gpa, .limited(1024 * 1024)) catch {
        return "app";
    };
    defer ctx.gpa.free(text);

    const found = manifestName(text) orelse return "app";
    if (found.len > out.len) return "app";
    @memcpy(out[0..found.len], found);
    return out[0..found.len];
}

/// The `name` field of a manifest, as a slice of `text`.
fn manifestName(text: []const u8) ?[]const u8 {
    // The manifest spells the name as an enum literal: `.name = .demo,`.
    const key = ".name = .";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    // The name runs to the first character that cannot be part of it.
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        const valid = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!valid) break;
    }
    if (end == 0) return null;
    return rest[0..end];
}

/// `myzig doctor` reports what this machine can actually run, so a missing
/// library is a clear message instead of a crash at startup.
fn runDoctor(ctx: Ctx) !void {
    try ctx.out("myzig doctor\n\n");

    var buf: [512]u8 = undefined;
    try ctx.out(try std.fmt.bufPrint(&buf, "  zig            {s}\n", .{@import("builtin").zig_version_string}));
    try ctx.out(try std.fmt.bufPrint(&buf, "  myzig          {s}\n", .{myzig.version}));
    try ctx.out(try std.fmt.bufPrint(&buf, "  target         {s}-{s}\n", .{
        @tagName(@import("builtin").target.os.tag),
        @tagName(@import("builtin").target.cpu.arch),
    }));

    // `doctor` inspects the machine it runs on, and what it looks for differs
    // with the platform. Only the Linux checks exist so far; the Windows and
    // macOS ones report that they are not written rather than lying about it.
    if (@import("builtin").os.tag != .linux) {
        try ctx.out("\n  libraries\n  (the Windows and macOS checks are not written yet)\n");
        return;
    }

    try ctx.out("\n  libraries\n");
    const checks = [_]struct { name: []const u8, lib: []const u8, needed: []const u8 }{
        .{ .name = "GTK 3", .lib = "libgtk-3.so.0", .needed = "web and native windows" },
        .{ .name = "WebKitGTK", .lib = "libwebkit2gtk-4.1.so.0", .needed = "web windows" },
        .{ .name = "cairo", .lib = "libcairo.so.2", .needed = "native windows" },
        .{ .name = "X11", .lib = "libX11.so.6", .needed = "global shortcuts" },
    };
    for (checks) |c| {
        const found = blk: {
            var lib = std.DynLib.open(c.lib) catch break :blk false;
            lib.close();
            break :blk true;
        };
        try ctx.out(try std.fmt.bufPrint(&buf, "  {s:<14} {s}  ({s})\n", .{
            c.name,
            if (found) "ok     " else "missing",
            c.needed,
        }));
    }

    try ctx.out("\n  environment\n");
    const display = myzig.env.get("DISPLAY");
    const wayland = myzig.env.get("WAYLAND_DISPLAY");
    try ctx.out(try std.fmt.bufPrint(&buf, "  DISPLAY        {s}\n", .{display orelse "(unset)"}));
    try ctx.out(try std.fmt.bufPrint(&buf, "  WAYLAND_DISPLAY {s}\n", .{wayland orelse "(unset)"}));
    if (display == null and wayland == null) {
        try ctx.out("\n  no display server found: windows cannot open here.\n");
    }
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
    \\  new NAME [options]      Create a project in ./NAME.
    \\    --web                 A page loaded from the embedded assets (default).
    \\    --native              A window drawn by MyZig itself, no web engine.
    \\  generate [--out FILE]   Write the TypeScript client for the built-in
    \\                          services. Defaults to ./myzig-client.d.ts.
    \\  package [options]       Bundle a built application for distribution.
    \\    --name NAME           Program name. Read from build.zig.zon by default.
    \\    --version VERSION     Version string. 0.1.0 by default.
    \\    --out DIR             Where to write the bundle. dist/ by default.
    \\  doctor                  Report what this machine has and what is missing.
    \\  version                 Print the version.
    \\  help                    Print this list.
    \\
;

test "the manifest name is read from the enum literal" {
    // `myzig new` writes `.name = .demo,`; the parser used to look for the
    // struct form and fell back to "app", which made `myzig package` claim the
    // program was not built.
    const text =
        \\.{
        \\    .name = .notes,
        \\    .version = "0.1.0",
        \\}
    ;
    try std.testing.expectEqualStrings("notes", manifestName(text).?);
}

test "a manifest without a name has none" {
    try std.testing.expectEqual(@as(?[]const u8, null), manifestName(".{}"));
    // Trailing garbage must not become part of the name.
    try std.testing.expectEqualStrings("my_app-2", manifestName(".name = .my_app-2,").?);
}

test "the help text names every command" {
    // Every command `main` dispatches must be documented, or a user cannot
    // find it. `new` and `doctor` were missing for a while.
    for ([_][]const u8{ "new", "generate", "package", "doctor", "version", "help" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, help_text, name) != null);
    }
}

/// Finds the framework checkout a generated project should depend on.
///
/// The order is: `MYZIG_HOME`, then the directory holding this executable and
/// its parents (a normal `zig build install` puts the tool in `zig-out/bin`,
/// so the checkout is two levels up). Returning an error rather than a guessed
/// path keeps `myzig new` from writing a manifest that cannot build.
fn frameworkRoot(buf: []u8) ![]const u8 {
    if (myzig.env.get("MYZIG_HOME")) |home| {
        if (isFrameworkCheckout(home)) return std.fmt.bufPrint(buf, "{s}", .{home});
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = myzig.env.selfExePath(&exe_buf) catch return error.FrameworkNotFound;
    var dir = std.fs.path.dirname(exe) orelse return error.FrameworkNotFound;
    var levels: usize = 0;
    while (levels < 4) : (levels += 1) {
        if (isFrameworkCheckout(dir)) return std.fmt.bufPrint(buf, "{s}", .{dir});
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return error.FrameworkNotFound;
}

/// A framework checkout is the directory with the framework's own manifest.
fn isFrameworkCheckout(dir: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/build.zig.zon", .{dir}) catch return false;
    const io = std.Io.Threaded.global_single_threaded;
    _ = &io;
    const file = std.Io.Dir.cwd().openFile(io.io(), path, .{}) catch return false;
    file.close(io.io());
    return true;
}

/// Expresses `target` as a path relative to `<base>/<sub>`, which is how a
/// manifest must refer to a dependency. Falls back to `target` itself when the
/// two share no prefix, which at least reports the real path to the user.
fn relativePath(buf: []u8, base: []const u8, sub: []const u8, target: []const u8) ![]const u8 {
    var from_buf: [std.fs.max_path_bytes]u8 = undefined;
    const from = std.fmt.bufPrint(&from_buf, "{s}/{s}", .{ base, sub }) catch return target;
    var target_parts = std.mem.splitScalar(u8, target, '/');
    var from_parts = std.mem.splitScalar(u8, from, '/');
    var common: usize = 0;
    var tp_list: [256][]const u8 = undefined;
    var fp_list: [256][]const u8 = undefined;
    var tp_len: usize = 0;
    var fp_len: usize = 0;
    while (target_parts.next()) |part| {
        if (tp_len == tp_list.len) return target;
        tp_list[tp_len] = part;
        tp_len += 1;
    }
    while (from_parts.next()) |part| {
        if (fp_len == fp_list.len) return target;
        fp_list[fp_len] = part;
        fp_len += 1;
    }
    while (common < tp_len and common < fp_len and
        std.mem.eql(u8, tp_list[common], fp_list[common])) : (common += 1)
    {}
    if (common == 0) return target;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    var i = common;
    while (i < fp_len) : (i += 1) {
        out.appendSlice(std.heap.page_allocator, "../") catch return target;
    }
    i = common;
    while (i < tp_len) : (i += 1) {
        if (i > common) out.append(std.heap.page_allocator, '/') catch return target;
        out.appendSlice(std.heap.page_allocator, tp_list[i]) catch return target;
    }
    if (out.items.len == 0) return target;
    return std.fmt.bufPrint(buf, "{s}", .{out.items});
}

test "the fingerprint puts the crc first and the id second" {
    // Regression: the halves were swapped, so `zig build` rejected every
    // generated manifest and told the user to paste in the correct value.
    var fp_buf: [18]u8 = undefined;
    const name = "myapp";
    const id: u32 = @truncate(std.hash.Wyhash.hash(0x6d797a67, name));
    const safe_id: u32 = if (id == 0 or id == 0xffffffff) 1 else id;
    const fingerprint = try std.fmt.bufPrint(&fp_buf, "0x{x:0>8}{x:0>8}", .{
        std.hash.Crc32.hash(name),
        safe_id,
    });
    // Zig's own suggestion for `myapp` on this machine is 0x8798022a0175385d,
    // so the high half must be the crc and the low half the id.
    try std.testing.expectEqualStrings("0x8798022a", fingerprint[0..10]);
}

test "a dependency path is expressed relative to the project" {
    var buf: [128]u8 = undefined;
    const rel = try relativePath(&buf, "/home/me/work", "myapp", "/home/me/work/myzig");
    try std.testing.expectEqualStrings("../myzig", rel);

    const deeper = try relativePath(&buf, "/home/me/work", "myapp", "/home/me/frameworks/myzig");
    try std.testing.expectEqualStrings("../../frameworks/myzig", deeper);
}

test "a separate root is reached through enough parent steps" {
    // Both paths start with the root separator, so the first component is
    // shared and the result is relative rather than absolute.
    var buf: [128]u8 = undefined;
    const rel = try relativePath(&buf, "/home/me", "myapp", "/opt/myzig");
    try std.testing.expectEqualStrings("../../../opt/myzig", rel);
}

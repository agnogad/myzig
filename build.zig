const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Backend selection. Empty means "choose from the target OS". A test build
    // passes `testing` so the framework runs with no display attached.
    const backend_opt = b.option(
        []const u8,
        "myzig_backend",
        "Platform backend: linux, windows, macos or testing (default: from target OS)",
    );

    const options = b.addOptions();
    if (backend_opt) |name| options.addOption([]const u8, "backend", name);

    // ---------------------------------------------------------------- module
    // `myzig` is the framework module application code imports.
    const myzig = b.addModule("myzig", .{
        .root_source_file = b.path("src/myzig.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    myzig.addOptions("myzig_options", options);
    configureNative(myzig, target);

    // ----------------------------------------------------------- examples
    // Each example is a standalone application that depends on the module.
    const examples = [_]struct { name: []const u8, path: []const u8, desc: []const u8 }{
        .{ .name = "hello-webview", .path = "examples/hello-webview/main.zig", .desc = "A window showing a web page served by MyZig" },
        .{ .name = "hello-window", .path = "examples/hello-window/main.zig", .desc = "Open and close a native window" },
        .{ .name = "ipc-greeter", .path = "examples/ipc-greeter/main.zig", .desc = "Typed Zig <-> TypeScript calls" },
        .{ .name = "plugins", .path = "examples/plugins/main.zig", .desc = "A plugin that binds a service and cleans up" },
        .{ .name = "counter-native", .path = "examples/counter-native/main.zig", .desc = "Native GPU-rendered counter UI" },
        .{ .name = "hybrid", .path = "examples/hybrid/main.zig", .desc = "Native chrome around a web view" },
        .{ .name = "desktop-api", .path = "examples/desktop-api/main.zig", .desc = "Clipboard, dialogs, notifications, tray" },
        .{ .name = "menus", .path = "examples/menus/main.zig", .desc = "Menu bar with accelerators" },
        .{ .name = "native-ui", .path = "examples/native-ui/main.zig", .desc = "A window drawn by MyZig itself: no web engine" },
        .{ .name = "tray", .path = "examples/tray/main.zig", .desc = "Tray icon and global shortcut" },
    };

    const run_all = b.step("examples", "Build all examples");
    for (examples) |ex| {
        {
            const exe = b.addExecutable(.{
                .name = ex.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(ex.path),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "myzig", .module = myzig }},
                }),
            });
            configureNative(exe.root_module, target);
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            const step = b.step(ex.name, ex.desc);
            step.dependOn(&run_cmd.step);
            run_all.dependOn(&exe.step);
        }
    }

    // ------------------------------------------------------------------ cli
    const cli_exe = b.addExecutable(.{
        .name = "myzig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    cli_exe.root_module.addOptions("myzig_options", options);
    cli_exe.root_module.link_libc = true;
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    const cli_step = b.step("cli", "Run the myzig command line tool");
    cli_step.dependOn(&run_cli.step);

    // ---------------------------------------------------------------- tests
    const test_step = b.step("test", "Run all unit and integration tests");

    const test_options = b.addOptions();
    test_options.addOption([]const u8, "backend", "testing");

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/myzig.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("myzig_options", test_options);
    configureNative(unit_tests.root_module, target);
    const run_unit = b.addRunArtifact(unit_tests);
    run_unit.has_side_effects = true;
    test_step.dependOn(&run_unit.step);

    // Integration tests exercise the public API through a separate root.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    integration_tests.root_module.addOptions("myzig_options", test_options);
    configureNative(integration_tests.root_module, target);
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.has_side_effects = true;
    test_step.dependOn(&run_integration.step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    cli_tests.root_module.addOptions("myzig_options", test_options);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    // --------------------------------------------------------------- benchs
    const bench_exe = b.addExecutable(.{
        .name = "myzig-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "myzig", .module = myzig }},
        }),
    });
    bench_exe.root_module.addOptions("myzig_options", options);
    configureNative(bench_exe.root_module, target);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);
}

/// Platform libraries the Linux backend talks to.
///
/// MyZig loads GTK, WebKitGTK, X11 and friends at run time through
/// `std.DynLib` so that an application links nothing platform specific and an
/// app whose windows show only native UI never maps WebKit. We still add the
/// include and library paths so that generated declarations stay verifiable,
/// and so that optional symbol lookups resolve at link time when present.
fn configureNative(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    mod.link_libc = true;
    // Linux links nothing: every system library is dlopen'd, which keeps
    // binaries small and lets MyZig start on a system missing one.
    //
    // Windows and macOS are the exceptions, for different reasons.
    //
    // Windows: `ProcessPrng` is the only entropy source still in the CRT's
    // reach, and it lives in `bcryptprimitives.dll`, which has to be named to
    // get an import library.
    //
    // macOS: `libobjc` and the frameworks are not optional and are not loaded
    // by name at runtime; the Objective-C runtime *is* the platform.
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("bcryptprimitives", .{});
    } else if (target.result.os.tag == .macos) {
        // A macOS build needs the platform SDK to find these, and a Linux host
        // has none. The backend is written and its *compilation* is checked
        // here; linking is checked on a Mac. Saying so is better than a build
        // that pretends to be cross-compiled for a system it cannot link for.
        //
        //   zig build -Dtarget=aarch64-macos -Dmacos-sdk=/path/to/MacOSX.sdk
    }
}

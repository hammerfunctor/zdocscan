const std = @import("std");
const Build = std.Build;

fn compilePotrace(
    b: *Build,
    exe: *Build.Step.Compile,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const dep_zlib = b.dependency("zlib", .{ .target = target, .optimize = optimize });

    exe.addIncludePath(b.path("c/potrace/"));

    // const config_h_step = b.addConfigHeader(.{
    //     .style = .{ .autoconf = b.path("c/potrace/config.h.in") },
    //     .include_path = "c/potrace/config.h", // The name of the output header file (relative to build dir)
    // }, .{
    //     // Provide values to substitute into config.h.in
    //     // These keys should match the MACRO_NAME part of the #undef's in config.h.in
    //     // .ENABLE_DEBUG = enable_debug,
    //     .POTRACE = "potrace",
    //     .VERSION = "1.16",
    //     .HAVE_STDINT_H = 1,
    //     .HAVE_ZLIB = 1,
    //     // .SYSTEM_OS = target.result.os.tag.toSlice(), // e.g., "linux", "macos", "windows"
    //     // .SYSTEM_IS_64BIT = target.result.arch.ptrBitWidth == 64,
    // });
    // exe.addIncludePath(config_h_step.getOutput());

    exe.addCSourceFiles(.{
        .root = b.path("c/potrace/"),
        .flags = &.{
            // "-DPOTRACE=\"potrace\"",
            // "-DVERSION=\"1.16\"",
            "-DHAVE_CONFIG_H=1",
        },
        .files = &.{
            "backend_pdf.c",
            "bitmap_io.c",
            "potracelib.c",
            "main.c",
            "flate.c",
            "lzw.c",
            "decompose.c",
            "trace.c",
            "curve.c",
            "trans.c",
            "bbox.c",
            "progress_bar.c",
            "backend_svg.c",
            "backend_eps.c",
            "backend_dxf.c",
            "backend_pgm.c",
            "backend_xfig.c",
            "backend_geojson.c",
            "greymap.c",
            "render.c",
            "getopt.c",
            "getopt1.c",
        },
    });
    exe.linkLibC();
    exe.linkLibrary(dep_zlib.artifact("z"));
}

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const dep_zstbi = b.dependency("zstbi", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zdocscan",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("clap", dep_clap.module("clap"));
    exe.root_module.addImport("zstbi", dep_zstbi.module("root"));

    const build_options = b.addOptions();

    const bundled_potrace = b.option(bool, "bundle-potrace", "Compile and bundle potrace.") orelse false;
    build_options.addOption(bool, "bundled_potrace", bundled_potrace);

    if (bundled_potrace) {
        compilePotrace(b, exe, target, optimize);
    }

    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args); // `zig build run -- arg1 arg2 etc`
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("zstbi", dep_zstbi.module("root"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("zstbi", dep_zstbi.module("root"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

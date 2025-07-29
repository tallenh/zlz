const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // Optional SIMD fast paths
    const simd_option = b.option(bool, "simd", "Enable SIMD fast paths (default: true)") orelse true;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "simd", simd_option);

    // Create a library target for the LZ and GLZ decoders
    const lib = b.addStaticLibrary(.{
        .name = "zlz",
        .root_source_file = b.path("src/lz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const logger = b.dependency("logger", .{ .target = target, .optimize = optimize });
    const logger_mod = logger.module("logger");
    lib.root_module.addImport("logger", logger_mod);
    lib.root_module.addOptions("build_options", build_opts);

    // Helper to inject the logger dependency into build steps that expose a
    // root_module field (executables, tests, etc.).
    const addImports = struct {
        fn apply(step: anytype, logger_mod_param: anytype, build_opts_param: anytype) void {
            const rm = @field(step, "root_module");
            rm.addImport("logger", logger_mod_param);
            rm.addOptions("build_options", build_opts_param);
        }
    };

    // This declares intent for the library to be installed-to and run-from
    // within the package installation directory (lib folder)
    b.installArtifact(lib);

    // Create an executable target for testing/demo purposes
    const exe = b.addExecutable(.{
        .name = "zlz-demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (bin folder)
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application has the same runtime
    // requirements regardless of the directory it is run from.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the demo application");
    run_step.dependOn(&run_cmd.step);

    // Create test executable for real frame processing
    const test_exe = b.addExecutable(.{
        .name = "test_real_frames",
        .root_source_file = b.path("src/test_real_frames.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link against system SDL3
    test_exe.linkSystemLibrary("SDL3");

    const test_run_cmd = b.addRunArtifact(test_exe);
    test_run_cmd.step.dependOn(b.getInstallStep());

    const test_frames_step = b.step("test-frames", "Test with real binary frames");
    test_frames_step.dependOn(&test_run_cmd.step);

    // Creates comprehensive test steps for all modules

    // Test the main library (LZ and GLZ decoders)
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Test the root library API
    const root_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_root_unit_tests = b.addRunArtifact(root_unit_tests);

    // Test LZ4 implementation
    const lz4_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test_lz4.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lz4_unit_tests = b.addRunArtifact(lz4_unit_tests);

    // Test zlib implementation
    const zlib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test_zlib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_zlib_unit_tests = b.addRunArtifact(zlib_unit_tests);

    // Main test step that runs all tests
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_root_unit_tests.step);
    test_step.dependOn(&run_lz4_unit_tests.step);
    test_step.dependOn(&run_zlib_unit_tests.step);

    // Individual test steps for granular testing
    const test_lz_step = b.step("test-lz", "Run LZ/GLZ decoder tests");
    test_lz_step.dependOn(&run_lib_unit_tests.step);

    // Regression test comparing against C reference decoder
    const lz_reg_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test_lz_regression.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add C source file
    lz_reg_unit_tests.addCSourceFile(.{
        .file = b.path("c_ref/lz_wrapper.c"),
        .flags = &.{"-std=c99"},
    });
    
    // Add include paths for C reference headers
    lz_reg_unit_tests.root_module.addIncludePath(b.path("c_ref"));
    lz_reg_unit_tests.root_module.addIncludePath(b.path("ref/spice-common/common"));
    lz_reg_unit_tests.root_module.addIncludePath(b.path("ref/spice-protocol"));
    lz_reg_unit_tests.root_module.addIncludePath(b.path("ref/spice-protocol/spice"));
    addImports.apply(lz_reg_unit_tests, logger_mod, build_opts);
    
    // Link C standard library
    lz_reg_unit_tests.linkLibC();
    
    const run_lz_reg_unit_tests = b.addRunArtifact(lz_reg_unit_tests);
    test_step.dependOn(&run_lz_reg_unit_tests.step);
    test_lz_step.dependOn(&run_lz_reg_unit_tests.step);

    const test_root_step = b.step("test-root", "Run root library API tests");
    test_root_step.dependOn(&run_root_unit_tests.step);

    const test_lz4_step = b.step("test-lz4", "Run LZ4 implementation tests");
    test_lz4_step.dependOn(&run_lz4_unit_tests.step);

    const test_zlib_step = b.step("test-zlib", "Run zlib implementation tests");
    test_zlib_step.dependOn(&run_zlib_unit_tests.step);

    // Executable demo
    addImports.apply(exe, logger_mod, build_opts);

    // Test executables
    addImports.apply(test_exe, logger_mod, build_opts);

    addImports.apply(lib_unit_tests, logger_mod, build_opts);
    addImports.apply(root_unit_tests, logger_mod, build_opts);
    addImports.apply(lz4_unit_tests, logger_mod, build_opts);
    addImports.apply(zlib_unit_tests, logger_mod, build_opts);

    // Root module that other projects import.
    const zlz_module = b.addModule("zlz", .{
        .root_source_file = b.path("src/root.zig"),
    });
    zlz_module.addImport("logger", logger_mod);
    zlz_module.addOptions("build_options", build_opts);

    // If more steps are added later that need logger, remember to call
    // addLoggerImport.apply on them.
}

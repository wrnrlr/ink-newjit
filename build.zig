const std = @import("std");

pub fn build(b: *std.Build) !void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  const enable_jit = b.option(bool, "jit", "Enable experimental arm64 JIT compiler") orelse false;

  // --- Dependencies ---
  const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
  const zpool_dep = b.dependency("zpool", .{ .target = target, .optimize = optimize });
  const zgpu_dep  = b.dependency("zgpu",  .{ .target = target, .optimize = optimize });
  const dawn_dep  = b.dependency("dawn_aarch64_macos", .{});
  const tatfi_dep = b.dependency("tatfi", .{});

  // --- GPU/graphics stack ---
  const zgpu_mod = zgpu_dep.module("root");
  zgpu_mod.addImport("zpool", zpool_dep.module("root"));
  const zdawn_lib = zgpu_dep.artifact("zdawn");

  // --- "ink" module: graphics rendering library (exposed to downstream packages) ---
  const ink_lib_mod = b.addModule("ink", .{
    .root_source_file = b.path("src/graphics/draw.zig"),
    .target = target,
    .optimize = optimize,
  });
  ink_lib_mod.addImport("zgpu",  zgpu_mod);
  ink_lib_mod.addImport("tatfi", tatfi_dep.module("tatfi"));

  // --- "lang" module: language runtime (exposed to downstream packages) ---
  const lang_mod = b.addModule("lang", .{
    .root_source_file = b.path("src/lang.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
  });
  lang_mod.addIncludePath(b.path("src"));
  lang_mod.addImport("ink", ink_lib_mod);

  // --- Tests ---
  const test_mod = b.createModule(.{
    .root_source_file = b.path("src/test.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const test_options = b.addOptions();
  test_options.addOption(bool, "enable_ui",  false);
  test_options.addOption(bool, "enable_jit", enable_jit);
  test_mod.addOptions("build_options", test_options);
  test_mod.addIncludePath(b.path("src"));
  const test_exe = b.addTest(.{ .root_module = test_mod });
  const test_run = b.addRunArtifact(test_exe);
  const test_step = b.step("test", "Run unit tests");
  test_step.dependOn(&test_run.step);

  // --- Corpus tests ---
  const corpus_mod = b.createModule(.{
    .root_source_file = b.path("src/corpus.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  corpus_mod.addIncludePath(b.path("src"));
  const corpus_exe = b.addTest(.{ .root_module = corpus_mod });
  const corpus_run = b.addRunArtifact(corpus_exe);
  const corpus_step = b.step("corpus", "Run corpus tests for the Zig parser");
  corpus_step.dependOn(&corpus_run.step);

  // --- ink runner (repl / file / stdin eval) ---
  const enable_ui = b.option(bool, "ui", "Enable UI/graphics support (GLFW + WebGPU window)") orelse false;
  const runner_options = b.addOptions();
  runner_options.addOption(bool, "enable_ui",  enable_ui);
  runner_options.addOption(bool, "enable_jit", enable_jit);

  const runner_mod = b.createModule(.{
    .root_source_file = b.path("src/runner.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const runner_exe = b.addExecutable(.{ .name = "ink", .root_module = runner_mod });
  runner_mod.addOptions("build_options", runner_options);
  runner_mod.addIncludePath(b.path("src"));

  if (enable_ui) {
    runner_mod.addImport("ink",   ink_lib_mod);
    runner_mod.addImport("zgpu",  zgpu_mod);
    runner_mod.addImport("zglfw", zglfw_dep.module("glfw"));
    runner_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    runner_mod.linkSystemLibrary("glfw", .{});
    runner_mod.addLibraryPath(dawn_dep.path(""));
    if (target.result.os.tag == .macos) {
      runner_mod.linkSystemLibrary("objc", .{});
      runner_mod.linkFramework("Metal", .{});
      runner_mod.linkFramework("CoreGraphics", .{});
      runner_mod.linkFramework("Foundation", .{});
      runner_mod.linkFramework("IOKit", .{});
      runner_mod.linkFramework("IOSurface", .{});
      runner_mod.linkFramework("QuartzCore", .{});
    }
    if (target.result.os.tag != .emscripten) {
      runner_mod.linkLibrary(zdawn_lib);
      runner_mod.linkSystemLibrary("dawn", .{});
    }
  }

  b.installArtifact(runner_exe);
  const runner_run_cmd = b.addRunArtifact(runner_exe);
  if (b.args) |run_args| runner_run_cmd.addArgs(run_args);
  const runner_step = b.step("run", "Run ink (repl / file / stdin eval)");
  runner_step.dependOn(&runner_run_cmd.step);

  // --- Window module for graphics demos ---
  const window_mod = b.createModule(.{
    .root_source_file = b.path("src/graphics/window.zig"),
    .target = target, .optimize = optimize,
  });
  window_mod.addImport("ink",   ink_lib_mod);
  window_mod.addImport("zgpu",  zgpu_mod);
  window_mod.addImport("zglfw", zglfw_dep.module("glfw"));

  // --- GPU backend test ---
  const gpu_test_mod = b.createModule(.{
    .root_source_file = b.path("src/gpu/gpu_wgpu_test.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  gpu_test_mod.addImport("zgpu", zgpu_mod);
  gpu_test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
  gpu_test_mod.addLibraryPath(dawn_dep.path(""));
  if (target.result.os.tag == .macos) {
    gpu_test_mod.linkSystemLibrary("objc", .{});
    gpu_test_mod.linkFramework("Metal", .{});
    gpu_test_mod.linkFramework("CoreGraphics", .{});
    gpu_test_mod.linkFramework("Foundation", .{});
    gpu_test_mod.linkFramework("IOKit", .{});
    gpu_test_mod.linkFramework("IOSurface", .{});
    gpu_test_mod.linkFramework("QuartzCore", .{});
  }
  gpu_test_mod.linkLibrary(zdawn_lib);
  gpu_test_mod.linkSystemLibrary("dawn", .{});
  const gpu_test_exe = b.addTest(.{ .root_module = gpu_test_mod });
  const gpu_test_run = b.addRunArtifact(gpu_test_exe);
  const gpu_test_step = b.step("test-gpu", "Run GPU backend tests (requires WebGPU)");
  gpu_test_step.dependOn(&gpu_test_run.step);

  // --- Graphics renderer demo ---
  const ink_demo_mod = b.createModule(.{
    .root_source_file = b.path("src/graphics/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const ink_demo_exe = b.addExecutable(.{ .name = "ink-demo", .root_module = ink_demo_mod });
  ink_demo_mod.addImport("ink",    ink_lib_mod);
  ink_demo_mod.addImport("zgpu",   zgpu_mod);
  ink_demo_mod.addImport("zglfw",  zglfw_dep.module("glfw"));
  ink_demo_mod.addImport("window", window_mod);
  ink_demo_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
  ink_demo_mod.linkSystemLibrary("glfw", .{});
  ink_demo_mod.addLibraryPath(dawn_dep.path(""));
  if (target.result.os.tag == .macos) {
    ink_demo_mod.linkSystemLibrary("objc", .{});
    ink_demo_mod.linkFramework("Metal", .{});
    ink_demo_mod.linkFramework("CoreGraphics", .{});
    ink_demo_mod.linkFramework("Foundation", .{});
    ink_demo_mod.linkFramework("IOKit", .{});
    ink_demo_mod.linkFramework("IOSurface", .{});
    ink_demo_mod.linkFramework("QuartzCore", .{});
  }
  if (target.result.os.tag != .emscripten) {
    ink_demo_mod.linkLibrary(zdawn_lib);
    ink_demo_mod.linkSystemLibrary("dawn", .{});
  }
  const ink_demo_run_cmd = b.addRunArtifact(ink_demo_exe);
  const ink_demo_step = b.step("demo", "Run the ink renderer demo");
  ink_demo_step.dependOn(&ink_demo_run_cmd.step);

  // --- Hello example ---
  const hello_mod = b.createModule(.{
    .root_source_file = b.path("src/graphics/hello.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const hello_exe = b.addExecutable(.{ .name = "hello", .root_module = hello_mod });
  hello_mod.addImport("ink",    ink_lib_mod);
  hello_mod.addImport("zgpu",   zgpu_mod);
  hello_mod.addImport("zglfw",  zglfw_dep.module("glfw"));
  hello_mod.addImport("window", window_mod);
  hello_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
  hello_mod.linkSystemLibrary("glfw", .{});
  hello_mod.addLibraryPath(dawn_dep.path(""));
  if (target.result.os.tag == .macos) {
    hello_mod.linkSystemLibrary("objc", .{});
    hello_mod.linkFramework("Metal", .{});
    hello_mod.linkFramework("CoreGraphics", .{});
    hello_mod.linkFramework("Foundation", .{});
    hello_mod.linkFramework("IOKit", .{});
    hello_mod.linkFramework("IOSurface", .{});
    hello_mod.linkFramework("QuartzCore", .{});
  }
  if (target.result.os.tag != .emscripten) {
    hello_mod.linkLibrary(zdawn_lib);
    hello_mod.linkSystemLibrary("dawn", .{});
  }
  const hello_run_cmd = b.addRunArtifact(hello_exe);
  const hello_step = b.step("hello", "Run the hello example");
  hello_step.dependOn(&hello_run_cmd.step);

  // --- Transpiler check ---
  const tr_mod = b.createModule(.{
    .root_source_file = b.path("src/graphics/transpiler.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  tr_mod.addImport("lang", lang_mod);
  ink_demo_mod.addImport("transpiler", tr_mod);
  const tr_check = b.addLibrary(.{ .name = "transpiler", .root_module = tr_mod, .linkage = .static });
  const tr_step = b.step("transpiler", "Type-check the WGSL transpiler");
  tr_step.dependOn(&tr_check.step);

  const tr_test_exe = b.addTest(.{ .root_module = tr_mod });
  const tr_test_run = b.addRunArtifact(tr_test_exe);
  const tr_test_step = b.step("test-transpiler", "Run transpiler tests");
  tr_test_step.dependOn(&tr_test_run.step);

  // --- Shape example ---
  const shape_mod = b.createModule(.{
    .root_source_file = b.path("src/graphics/example.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  shape_mod.addImport("tatfi", tatfi_dep.module("tatfi"));
  const shape_exe = b.addExecutable(.{ .name = "shape", .root_module = shape_mod });
  b.installArtifact(shape_exe);
  const shape_run_cmd = b.addRunArtifact(shape_exe);
  const shape_step = b.step("shape", "Run the font shaping example");
  shape_step.dependOn(&shape_run_cmd.step);
}

const std = @import("std");

pub fn build(b: *std.Build) !void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  const paranoid = b.option(bool, "paranoid", "Enable extra runtime validation") orelse false;

  // --- Tests ---
  const test_mod = b.createModule(.{
    .root_source_file = b.path("src/test.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const test_options = b.addOptions();
  test_options.addOption(bool, "enable_ui", false);
  test_options.addOption(bool, "paranoid",  paranoid);
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

  // --- ink runner (core, no GPU dependency) ---
  const runner_options = b.addOptions();
  runner_options.addOption(bool, "enable_ui", false);
  runner_options.addOption(bool, "paranoid",  paranoid);

  const runner_mod = b.createModule(.{
    .root_source_file = b.path("src/runner.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const runner_exe = b.addExecutable(.{ .name = "ink", .root_module = runner_mod });
  runner_exe.rdynamic = true;  // export k_* symbols so dlopen'd extensions can find them
  runner_mod.addOptions("build_options", runner_options);
  runner_mod.addIncludePath(b.path("src"));

  b.installArtifact(runner_exe);
  const runner_run_cmd = b.addRunArtifact(runner_exe);
  if (b.args) |run_args| runner_run_cmd.addArgs(run_args);
  const runner_step = b.step("run", "Run ink (repl / file / stdin eval)");
  runner_step.dependOn(&runner_run_cmd.step);

  // --- GPU extension shared library (~20MB with Dawn) ---
  const zgpu_dep  = b.dependency("zgpu",  .{ .target = target, .optimize = optimize });
  const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
  const zpool_dep = b.dependency("zpool", .{ .target = target, .optimize = optimize });
  // zgpu requires zpool but doesn't declare it in its module
  zgpu_dep.module("root").addImport("zpool", zpool_dep.module("root"));

  const gpu_render_mod = b.createModule(.{
    .root_source_file = b.path("lib/gpu/render.zig"),
    .target = target, .optimize = optimize,
  });
  gpu_render_mod.addImport("zgpu", zgpu_dep.module("root"));

  const gpu_tri_mod = b.createModule(.{
    .root_source_file = b.path("lib/gpu/triangulate.zig"),
    .target = target, .optimize = optimize,
  });

  const gpu_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/gpu/src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  gpu_ext_mod.addImport("zgpu",       zgpu_dep.module("root"));
  gpu_ext_mod.addImport("zglfw",      zglfw_dep.module("glfw"));
  gpu_ext_mod.addImport("render",     gpu_render_mod);
  gpu_ext_mod.addImport("triangulate", gpu_tri_mod);

  const dawn_dep = b.dependency("dawn_aarch64_macos", .{});

  // zdawn adapter: compiles dawn_proc.c + dawn.cpp (C API + proc-table dispatch)
  const zdawn = zgpu_dep.artifact("zdawn");
  gpu_ext_mod.linkLibrary(zdawn);

  // libdawn.a (prebuilt Dawn WebGPU backend) — add its dir to the final dylib link
  gpu_ext_mod.addLibraryPath(dawn_dep.path("."));
  gpu_ext_mod.linkSystemLibrary("dawn", .{ .preferred_link_mode = .static });

  // GLFW (Homebrew) and required macOS frameworks
  gpu_ext_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
  gpu_ext_mod.linkSystemLibrary("glfw3", .{ .preferred_link_mode = .static });
  gpu_ext_mod.linkFramework("Metal",       .{});
  gpu_ext_mod.linkFramework("QuartzCore",  .{});
  gpu_ext_mod.linkFramework("Foundation",  .{});
  gpu_ext_mod.linkFramework("IOKit",       .{});
  gpu_ext_mod.linkFramework("IOSurface",   .{});
  gpu_ext_mod.linkFramework("Cocoa",       .{});

  const gpu_lib = b.addLibrary(.{
    .name     = "gpu",
    .root_module = gpu_ext_mod,
    .linkage  = .dynamic,
  });
  b.installArtifact(gpu_lib);
  const gpu_step = b.step("gpu", "Build the GPU extension shared library");
  gpu_step.dependOn(&b.addInstallArtifact(gpu_lib, .{}).step);

  // --- Font extension shared library ---
  const tatfi_dep = b.dependency("tatfi", .{});

  const font_ext_impl_mod = b.createModule(.{
    .root_source_file = b.path("lib/font/font_ext.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  font_ext_impl_mod.addImport("tatfi", tatfi_dep.module("tatfi"));

  const font_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/font/src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  font_ext_mod.addImport("font_ext", font_ext_impl_mod);

  const font_lib = b.addLibrary(.{
    .name     = "font",
    .root_module = font_ext_mod,
    .linkage  = .dynamic,
  });
  b.installArtifact(font_lib);
  const font_step = b.step("font", "Build the font extension shared library");
  font_step.dependOn(&b.addInstallArtifact(font_lib, .{}).step);

  // --- MD5 extension shared library ---
  const md5_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/md5/src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });

  const md5_lib = b.addLibrary(.{
    .name     = "md5",
    .root_module = md5_ext_mod,
    .linkage  = .dynamic,
  });
  b.installArtifact(md5_lib);
  const md5_step = b.step("md5", "Build the MD5 extension shared library");
  md5_step.dependOn(&b.addInstallArtifact(md5_lib, .{}).step);
}

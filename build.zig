const std = @import("std");

pub fn build(b: *std.Build) !void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  const enable_jit = b.option(bool, "jit", "Enable experimental arm64 JIT compiler") orelse false;
  const paranoid   = b.option(bool, "paranoid", "Enable extra runtime validation (e.g. JIT stencil shape checks)") orelse false;

  // --- AOT stencil pipeline (Phase 1) ---
  // 1. Compile stencils_src.zig to an object file at ReleaseFast, regardless
  //    of the parent build mode. ReleaseFast is what guarantees true tail-call
  //    lowering and clean relocation entries.
  // 2. Run tools/extract_stencils.zig over that .o to emit a generated
  //    stencil_data.zig containing byte arrays + hole offsets.
  // 3. Expose stencil_data as a module so consumers can @import("stencil_data").
  const stencils_mod = b.createModule(.{
    .root_source_file = b.path("src/runtime/jit/stencils_src.zig"),
    .target = target,
    .optimize = .ReleaseFast,
  });
  const stencils_obj = b.addObject(.{ .name = "stencils_src", .root_module = stencils_mod });

  const extractor_mod = b.createModule(.{
    .root_source_file = b.path("tools/extract_stencils.zig"),
    .target = b.graph.host,
    .optimize = .ReleaseFast,
  });
  const extractor_exe = b.addExecutable(.{ .name = "extract_stencils", .root_module = extractor_mod });

  const extract_run = b.addRunArtifact(extractor_exe);
  extract_run.addFileArg(stencils_obj.getEmittedBin());
  const stencil_data_file = extract_run.addOutputFileArg("stencil_data.zig");

  const stencil_data_mod = b.createModule(.{
    .root_source_file = stencil_data_file,
    .target = target,
    .optimize = optimize,
  });

  const extract_step = b.step("extract-stencils", "Compile stencils_src and run the extractor");
  extract_step.dependOn(&extract_run.step);

  // Smoke test for the AOT pipeline. Runs add_ii→return through a tiny
  // hand-coded VM and asserts the result.
  const smoke_mod = b.createModule(.{
    .root_source_file = b.path("tools/smoke_stencils.zig"),
    .target = b.graph.host,
    .optimize = .ReleaseFast,
    .link_libc = true,
  });
  smoke_mod.addImport("stencil_data", stencil_data_mod);
  const smoke_exe = b.addExecutable(.{ .name = "smoke_stencils", .root_module = smoke_mod });
  const smoke_run = b.addRunArtifact(smoke_exe);
  const smoke_step = b.step("smoke-stencils", "Run the Phase-1 stencil pipeline smoke test");
  smoke_step.dependOn(&smoke_run.step);

  // --- Tests ---
  const test_mod = b.createModule(.{
    .root_source_file = b.path("src/test.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const test_options = b.addOptions();
  test_options.addOption(bool, "enable_ui",  false);
  test_options.addOption(bool, "enable_jit", enable_jit);
  test_options.addOption(bool, "paranoid",   paranoid);
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

  // --- ink runner ---
  const runner_options = b.addOptions();
  runner_options.addOption(bool, "enable_ui",  false);
  runner_options.addOption(bool, "enable_gpu", false);
  runner_options.addOption(bool, "enable_jit", enable_jit);
  runner_options.addOption(bool, "paranoid",   paranoid);

  const runner_mod = b.createModule(.{
    .root_source_file = b.path("src/runner.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const runner_exe = b.addExecutable(.{ .name = "ink", .root_module = runner_mod });
  runner_mod.addOptions("build_options", runner_options);
  runner_mod.addIncludePath(b.path("src"));

  b.installArtifact(runner_exe);
  const runner_run_cmd = b.addRunArtifact(runner_exe);
  if (b.args) |run_args| runner_run_cmd.addArgs(run_args);
  const runner_step = b.step("run", "Run ink (repl / file / stdin eval)");
  runner_step.dependOn(&runner_run_cmd.step);
}

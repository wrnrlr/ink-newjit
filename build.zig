const std = @import("std");

pub fn build(b: *std.Build) !void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  const paranoid   = b.option(bool, "paranoid", "Enable extra runtime validation") orelse false;

  // --- Tests ---
  const test_mod = b.createModule(.{
    .root_source_file = b.path("src/test.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const test_options = b.addOptions();
  test_options.addOption(bool, "enable_ui",  false);
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

const std = @import("std");

pub fn build(b: *std.Build) !void {
  const target   = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  const paranoid = b.option(bool, "paranoid", "Enable extra runtime validation") orelse false;
  const version  = b.option([]const u8, "version", "Release version string") orelse "0.1.0";
  // Output name for the ink binary; `make all` sets this per target
  // (e.g. ink-linux-x64) so cross-built binaries land at distinct paths.
  const exe_name = b.option([]const u8, "exe-name", "Name of the ink executable") orelse "ink";

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

  // --- ink runner (core, no GPU dependency) ---
  const runner_options = b.addOptions();
  runner_options.addOption(bool, "enable_ui", false);
  runner_options.addOption(bool, "paranoid",  paranoid);
  runner_options.addOption([]const u8, "version", version);

  const runner_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  const runner_exe = b.addExecutable(.{ .name = exe_name, .root_module = runner_mod });
  runner_exe.rdynamic = true;  // export k_* symbols so dlopen'd extensions can find them
  runner_mod.addOptions("build_options", runner_options);
  runner_mod.addIncludePath(b.path("src"));

  b.installArtifact(runner_exe);
  const runner_run_cmd = b.addRunArtifact(runner_exe);
  if (b.args) |run_args| runner_run_cmd.addArgs(run_args);
  const runner_step = b.step("run", "Run ink (repl / file / stdin eval)");
  runner_step.dependOn(&runner_run_cmd.step);

  // `zig build bin` installs only the ink binary — used by `make all` to
  // cross-compile the core runner without the (macOS-only) native extensions.
  const bin_step = b.step("bin", "Build just the ink binary");
  bin_step.dependOn(&b.addInstallArtifact(runner_exe, .{}).step);

  // --- Unicode binary data (lib/data.kb) ---
  // Defined before the `core-only` early return so a dependency-free build can
  // still (re)generate lib/data.kb — it is purely host codegen from the unicode
  // tables embedded in lib/font/data.zig and pulls in no external packages.
  const data_gen_mod = b.createModule(.{
    .root_source_file = b.path("lib/data_gen.zig"),
    // No libc: data_gen uses page_allocator + raw syscalls, so it links fully
    // static and runs in libc-less build sandboxes (Nix/CI) where a dynamically
    // linked host tool can't find the system loader.
    .target = target, .optimize = optimize,
  });
  const data_gen_exe = b.addExecutable(.{
    .name = "data_gen",
    .root_module = data_gen_mod,
  });
  const run_data_gen = b.addRunArtifact(data_gen_exe);
  const data_step = b.step("data", "Regenerate lib/data.kb from unicode tables");
  data_step.dependOn(&run_data_gen.step);

  // `-Dcore-only` skips the native extension graph entirely (Dawn/Metal/GLFW),
  // which only links on macOS; cross builds pass it so the dependency graph
  // never references the host-only toolchain.
  const core_only = b.option(bool, "core-only", "Build only the ink binary, no extensions") orelse false;
  if (core_only) return;

  // Canonical k-ABI definition shared by the host and extensions (src/kabi.zig),
  // so native extensions import the registry layout instead of mirroring it.
  const kabi_mod = b.createModule(.{
    .root_source_file = b.path("src/kabi.zig"),
    .target = target, .optimize = optimize,
  });

  // Static .a libraries for `ink bundle` (linked, not dlopen'd).  Contributed to
  // from here (gpu, below) and after the light extensions are defined.
  const static_step = b.step("static", "Build static .a libs (core + extensions) for bundling");

  // The GPU extension links MoltenVK + macOS frameworks, so it only builds for
  // aarch64-macos.  Gating it (rather than the whole extension graph) lets the
  // light extensions and static .a libs cross-compile for the other targets.
  if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64) blk: {
  // ── GPU extension: raw Vulkan via MoltenVK (SPIR-V-native) ──────────────────
  // Links libMoltenVK + Homebrew vulkan-headers + GLFW; dye.k's SPIR-V goes
  // straight to vkCreateShaderModule (no Tint/WGSL toolchain). The old
  // Dawn/WebGPU backend was removed at cutover — see doc/design/vulkan-migration.md.
  // zglfw is lazy: when not yet cached, lazyDependency enqueues the fetch,
  // returns null, and Zig re-runs build() once it completes.
  const mvk = "/opt/homebrew/opt/molten-vk";
  const vkh = "/opt/homebrew/opt/vulkan-headers/include";
  const zglfw_dep = b.lazyDependency("zglfw", .{ .target = target, .optimize = optimize }) orelse break :blk;
  const vk_tri_mod = b.createModule(.{
    .root_source_file = b.path("lib/gpu/triangulate.zig"),
    .target = target, .optimize = optimize,
  });
  const vk_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/gpu/gpu_vk.zig"),
    .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true,
  });
  vk_ext_mod.addImport("kabi", kabi_mod);
  vk_ext_mod.addImport("zglfw", zglfw_dep.module("glfw"));
  vk_ext_mod.addImport("triangulate", vk_tri_mod);
  vk_ext_mod.addIncludePath(.{ .cwd_relative = vkh });
  vk_ext_mod.addLibraryPath(.{ .cwd_relative = mvk ++ "/lib" });
  vk_ext_mod.linkSystemLibrary("MoltenVK", .{ .preferred_link_mode = .static });
  vk_ext_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
  vk_ext_mod.linkSystemLibrary("glfw3", .{ .preferred_link_mode = .static });
  vk_ext_mod.linkFramework("Metal", .{});
  vk_ext_mod.linkFramework("Foundation", .{});
  vk_ext_mod.linkFramework("QuartzCore", .{});
  vk_ext_mod.linkFramework("IOKit", .{});
  vk_ext_mod.linkFramework("IOSurface", .{});
  vk_ext_mod.linkFramework("CoreGraphics", .{});
  vk_ext_mod.linkFramework("Cocoa", .{});
  vk_ext_mod.linkFramework("AppKit", .{});
  const vk_lib = b.addLibrary(.{ .name = "gpu", .root_module = vk_ext_mod, .linkage = .dynamic });
  // Keep dead-strip OFF: a ReleaseFast link otherwise strips the static
  // MoltenVK archive's ObjC selector/class metadata and every vkCreateInstance
  // crashes with "+[NSProcessInfo processInfo]: unrecognized selector" inside
  // mvkGetEnvVarNumber (Debug links only worked because they don't gc). The
  // ~1MB size cost is the price of a working release GPU extension.
  vk_lib.link_gc_sections = false;
  b.installArtifact(vk_lib);
  const vk_step = b.step("gpu", "Build the GPU extension shared library (Vulkan/MoltenVK)");
  vk_step.dependOn(&b.addInstallArtifact(vk_lib, .{}).step);

  // Static gpu archive for bundling.  A static .a doesn't absorb its native
  // dependencies, so merge gpu + MoltenVK + GLFW into one archive with libtool;
  // `ink bundle` then links just libgpu-bundle.a + -lc++ + the macOS frameworks.
  const gpu_static = b.addLibrary(.{ .name = "gpu", .root_module = vk_ext_mod, .linkage = .static });
  const merge = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
  const merged = merge.addOutputFileArg("libgpu-bundle.a");
  merge.addArtifactArg(gpu_static);
  merge.addFileArg(.{ .cwd_relative = mvk ++ "/lib/libMoltenVK.a" });
  merge.addFileArg(.{ .cwd_relative = "/opt/homebrew/lib/libglfw3.a" });
  static_step.dependOn(&b.addInstallLibFile(merged, "libgpu-bundle.a").step);
  } // end macOS-only GPU section

  // --- Font extension shared library (native sfnt parser, no tatfi) ---
  const font_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/font/ext.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  font_ext_mod.addImport("kabi", kabi_mod);

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
    .root_source_file = b.path("lib/md5/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  md5_ext_mod.addImport("kabi", kabi_mod);

  const md5_lib = b.addLibrary(.{
    .name     = "md5",
    .root_module = md5_ext_mod,
    .linkage  = .dynamic,
  });
  b.installArtifact(md5_lib);
  const md5_step = b.step("md5", "Build the MD5 extension shared library");
  md5_step.dependOn(&b.addInstallArtifact(md5_lib, .{}).step);

  // --- JSON extension shared library ---
  const json_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/json/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  json_ext_mod.addImport("kabi", kabi_mod);

  const json_lib = b.addLibrary(.{ .name = "json", .root_module = json_ext_mod, .linkage = .dynamic });
  b.installArtifact(json_lib);
  const json_step = b.step("json", "Build the JSON extension shared library");
  json_step.dependOn(&b.addInstallArtifact(json_lib, .{}).step);

  // --- CSV extension shared library ---
  const csv_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/csv/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  csv_ext_mod.addImport("kabi", kabi_mod);

  const csv_lib = b.addLibrary(.{ .name = "csv", .root_module = csv_ext_mod, .linkage  = .dynamic });
  b.installArtifact(csv_lib);
  const csv_step = b.step("csv", "Build the CSV extension shared library");
  csv_step.dependOn(&b.addInstallArtifact(csv_lib, .{}).step);

  // --- Crypto extension shared library ---
  const crypto_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/crypto/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  crypto_ext_mod.addImport("kabi", kabi_mod);

  const crypto_lib = b.addLibrary(.{ .name = "crypto", .root_module = crypto_ext_mod, .linkage = .dynamic });
  b.installArtifact(crypto_lib);
  const crypto_step = b.step("crypto", "Build the crypto extension shared library");
  crypto_step.dependOn(&b.addInstallArtifact(crypto_lib, .{}).step);

  // --- Compress extension shared library ---
  const compress_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/compress/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  compress_ext_mod.addImport("kabi", kabi_mod);

  const compress_lib = b.addLibrary(.{ .name = "compress", .root_module = compress_ext_mod, .linkage = .dynamic });
  b.installArtifact(compress_lib);
  const compress_step = b.step("compress", "Build the compress extension shared library");
  compress_step.dependOn(&b.addInstallArtifact(compress_lib, .{}).step);

  // --- Zip extension shared library ---
  const zip_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/zip/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  zip_ext_mod.addImport("kabi", kabi_mod);

  const zip_lib = b.addLibrary(.{ .name = "zip", .root_module = zip_ext_mod, .linkage = .dynamic });
  b.installArtifact(zip_lib);
  const zip_step = b.step("zip", "Build the zip extension shared library");
  zip_step.dependOn(&b.addInstallArtifact(zip_lib, .{}).step);

  // --- HTTP client extension shared library ---
  const http_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/http/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  http_ext_mod.addImport("kabi", kabi_mod);

  const http_lib = b.addLibrary(.{ .name = "http", .root_module = http_ext_mod, .linkage = .dynamic });
  b.installArtifact(http_lib);
  const http_step = b.step("http", "Build the HTTP client extension shared library");
  http_step.dependOn(&b.addInstallArtifact(http_lib, .{}).step);

  // --- Parquet extension shared library ---
  const parquet_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/parquet/src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  parquet_ext_mod.addImport("kabi", kabi_mod);

  const parquet_lib = b.addLibrary(.{ .name = "parquet", .root_module = parquet_ext_mod, .linkage = .dynamic });
  b.installArtifact(parquet_lib);
  const parquet_step = b.step("parquet", "Build the Parquet extension shared library");
  parquet_step.dependOn(&b.addInstallArtifact(parquet_lib, .{}).step);

  // --- Safetensors extension shared library ---
  const safetensors_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/safetensors/src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  safetensors_ext_mod.addImport("kabi", kabi_mod);

  const safetensors_lib = b.addLibrary(.{ .name = "safetensors", .root_module = safetensors_ext_mod, .linkage = .dynamic });
  b.installArtifact(safetensors_lib);
  const safetensors_step = b.step("safetensors", "Build the Safetensors extension shared library");
  safetensors_step.dependOn(&b.addInstallArtifact(safetensors_lib, .{}).step);

  // --- Shapefile extension shared library ---
  const shp_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/shp/src/main.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  shp_ext_mod.addImport("kabi", kabi_mod);
  const shp_lib = b.addLibrary(.{ .name = "shp", .root_module = shp_ext_mod, .linkage = .dynamic });
  b.installArtifact(shp_lib);
  const shp_step = b.step("shp", "Build the shapefile extension shared library");
  shp_step.dependOn(&b.addInstallArtifact(shp_lib, .{}).step);

  // --- Audio extension (miniaudio) ---
  // A C shim (lib/audio/shim.c) compiles the miniaudio single-header
  // implementation and exposes a small integer-handle C ABI; audio.zig bridges
  // it to the k-ABI. miniaudio dynamically loads the backend at runtime, so the
  // only link-time deps are the macOS CoreAudio frameworks.
  const audio_ext_mod = b.createModule(.{
    .root_source_file = b.path("lib/audio/audio.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  audio_ext_mod.addImport("kabi", kabi_mod);
  audio_ext_mod.addIncludePath(b.path("lib/audio"));
  audio_ext_mod.addCSourceFile(.{
    .file = b.path("lib/audio/shim.c"),
    .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
  });
  if (target.result.os.tag == .macos) {
    audio_ext_mod.linkFramework("CoreFoundation", .{});
    audio_ext_mod.linkFramework("CoreAudio",      .{});
    audio_ext_mod.linkFramework("AudioToolbox",   .{});
  }
  const audio_lib = b.addLibrary(.{ .name = "audio", .root_module = audio_ext_mod, .linkage = .dynamic });
  b.installArtifact(audio_lib);
  const audio_step = b.step("audio", "Build the audio extension shared library");
  audio_step.dependOn(&b.addInstallArtifact(audio_lib, .{}).step);

  // --- Image extensions (one shared library per format, sharing lib/image/*) ---
  // libimage holds the format-agnostic helpers (sniff + resample); libpng,
  // libjpeg, … each bundle only their decoder so `ink bundle` links just what a
  // program uses. Every ext root imports kabi and the shared image sources.
  const image_exts = .{
    .{ "image", "lib/image/image_ext.zig" },
    .{ "png", "lib/image/png_ext.zig" },
    .{ "jpeg", "lib/image/jpeg_ext.zig" },
    .{ "bmp", "lib/image/bmp_ext.zig" },
    .{ "tga", "lib/image/tga_ext.zig" },
    .{ "gif", "lib/image/gif_ext.zig" },
    .{ "hdr", "lib/image/hdr_ext.zig" },
    .{ "pic", "lib/image/pic_ext.zig" },
    .{ "tiff", "lib/image/tiff_ext.zig" },
  };
  const image_step = b.step("images", "Build all image extension shared libraries");
  inline for (image_exts) |pair| {
    const mod = b.createModule(.{
      .root_source_file = b.path(pair[1]),
      .target = target, .optimize = optimize, .link_libc = true,
    });
    mod.addImport("kabi", kabi_mod);
    const lib = b.addLibrary(.{ .name = pair[0], .root_module = mod, .linkage = .dynamic });
    b.installArtifact(lib);
    const step = b.step(pair[0], "Build the " ++ pair[0] ++ " image extension shared library");
    step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    image_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    // Static archive too, so `ink bundle` can link only the formats a program uses.
    const slib = b.addLibrary(.{ .name = pair[0], .root_module = mod, .linkage = .static });
    static_step.dependOn(&b.addInstallArtifact(slib, .{}).step);
  }

  // --- Static .a libraries for `ink bundle` (linked, not dlopen'd) ---
  // The interpreter core as a linkable archive (exposes the C-ABI
  // `ink_run_bundle` entry; no `main`), plus a static .a per light extension.
  // `ink bundle` links these with the generated glue into one native exe.
  const corelib_mod = b.createModule(.{
    .root_source_file = b.path("src/corelib.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
  });
  corelib_mod.addOptions("build_options", runner_options);
  corelib_mod.addIncludePath(b.path("src"));
  const core_lib = b.addLibrary(.{ .name = "ink-core", .root_module = corelib_mod, .linkage = .static });

  static_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);
  inline for (.{
    .{ "json", json_ext_mod },   .{ "csv", csv_ext_mod }, .{ "md5", md5_ext_mod },
    .{ "font", font_ext_mod }, .{ "parquet", parquet_ext_mod }, .{ "shp", shp_ext_mod },
    .{ "safetensors", safetensors_ext_mod }, .{ "crypto", crypto_ext_mod },
    .{ "compress", compress_ext_mod }, .{ "zip", zip_ext_mod },
    .{ "http", http_ext_mod },
  }) |pair| {
    const slib = b.addLibrary(.{ .name = pair[0], .root_module = pair[1], .linkage = .static });
    static_step.dependOn(&b.addInstallArtifact(slib, .{}).step);
  }
}

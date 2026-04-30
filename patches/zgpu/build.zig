const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const options = .{
        .uniforms_buffer_size = b.option(u64, "uniforms_buffer_size", "") orelse (4 * 1024 * 1024),
        .dawn_skip_validation = b.option(bool, "dawn_skip_validation", "") orelse false,
        .dawn_allow_unsafe_apis = b.option(bool, "dawn_allow_unsafe_apis", "") orelse false,
        .buffer_pool_size = b.option(u32, "buffer_pool_size", "") orelse 256,
        .texture_pool_size = b.option(u32, "texture_pool_size", "") orelse 256,
        .texture_view_pool_size = b.option(u32, "texture_view_pool_size", "") orelse 256,
        .sampler_pool_size = b.option(u32, "sampler_pool_size", "") orelse 16,
        .render_pipeline_pool_size = b.option(u32, "render_pipeline_pool_size", "") orelse 128,
        .compute_pipeline_pool_size = b.option(u32, "compute_pipeline_pool_size", "") orelse 128,
        .bind_group_pool_size = b.option(u32, "bind_group_pool_size", "") orelse 32,
        .bind_group_layout_pool_size = b.option(u32, "bind_group_layout_pool_size", "") orelse 32,
        .pipeline_layout_pool_size = b.option(u32, "pipeline_layout_pool_size", "") orelse 32,
        .max_num_bindings_per_group = b.option(u32, "max_num_bindings_per_group", "") orelse 10,
        .max_num_bind_groups_per_pipeline = b.option(u32, "max_num_bind_groups_per_pipeline", "") orelse 4,
    };

    const options_step = b.addOptions();
    inline for (std.meta.fields(@TypeOf(options))) |field| {
        options_step.addOption(field.type, field.name, @field(options, field.name));
    }

    const zgpu_mod = b.addModule("root", .{
        .root_source_file = b.path("upstream/src/zgpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    zgpu_mod.addImport("zgpu_options", options_step.createModule());

    const zdawn = b.addLibrary(.{
        .name = "zdawn",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = (target.result.abi != .msvc),
        }),
    });

    zdawn.root_module.addIncludePath(b.path("upstream/libs/dawn/include"));
    zdawn.root_module.addIncludePath(b.path("upstream/src"));
    zdawn.root_module.addCSourceFile(.{
        .file = b.path("upstream/src/dawn.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    zdawn.root_module.addCSourceFile(.{
        .file = b.path("upstream/src/dawn_proc.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });
    b.installArtifact(zdawn);
}

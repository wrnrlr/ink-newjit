/// GPU extension for ink — loaded via `"./zig-out/lib/libgpu.dylib" 2: (`gpu_run; 2)`.
///
/// K API (after loading via lib/gpu/gpu.k):
///   gpu_run[loop_fn; config]   blocking event loop; calls loop_fn(props) each frame
///   gpu_fill[verts_F; frag_F]  draw triangles (call inside frame callback)
///   gpu_tess[pts_F]            tessellate polygon → flat F vertex array
///
/// props dict passed to loop_fn each frame:
///   {width: f; height: f; mx: f; my: f; time: f}
///
/// Host K API imported via dynamic linker (exported by the ink binary):
///   k_call, k_make_dict, ki, kf, kn, kfp, ku, KF

const std = @import("std");
const zglfw = @import("zglfw");
const zgpu  = @import("zgpu");
const wgpu  = zgpu.wgpu;
const render = @import("render");
const tri    = @import("triangulate");
const Renderer = render.Renderer;

// ── Host K API — resolved at init time via dlsym ─────────────────────────────

const K = *anyopaque;

// macOS RTLD_DEFAULT = (void*)-2; finds symbols in any already-loaded image.
const RTLD_DEFAULT = @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))));
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

const KApi = struct {
    k_call:      *const fn (K, K) callconv(.c) ?K,
    k_make_dict: *const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K,
    kf:          *const fn (f32) callconv(.c) ?K,
    ki:          *const fn (i32) callconv(.c) ?K,
    kn:          *const fn (?K) callconv(.c) i32,
    kfp:         *const fn (?K) callconv(.c) ?[*]f32,
    kip:         *const fn (?K) callconv(.c) ?[*]i32,
    ki_val:      *const fn (?K) callconv(.c) i32,
    KF:          *const fn (i32) callconv(.c) ?K,
    ku:          *const fn (?K) callconv(.c) void,
};
var g_api: ?KApi = null;

fn lookupFn(comptime T: type, name: [*:0]const u8) ?T {
    const ptr = dlsym(RTLD_DEFAULT, name) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// Thin wrappers so the rest of the file can call ki/kf/etc. without changing.
fn ki(v: i32) ?K         { return g_api.?.ki(v); }
fn kf(v: f32) ?K         { return g_api.?.kf(v); }
fn kn(x: ?K) i32         { return g_api.?.kn(x); }
fn kfp(x: ?K) ?[*]f32   { return g_api.?.kfp(x); }
fn kip(x: ?K) ?[*]i32   { return g_api.?.kip(x); }
fn ki_val(x: ?K) i32    { return g_api.?.ki_val(x); }
fn KF(n: i32) ?K         { return g_api.?.KF(n); }
fn ku(x: ?K) void        { g_api.?.ku(x); }
fn k_call(f: K, a: K) ?K { return g_api.?.k_call(f, a); }
fn k_make_dict(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?K) ?K {
    return g_api.?.k_make_dict(n, keys, vals);
}

// ── Frame-local renderer (set while the frame callback executes) ───────────────

var g_renderer: ?*Renderer = null;

// ── gpu_fill ──────────────────────────────────────────────────────────────────
//
// verts_F: flat f32 array, stride 4 [x, y, u, v] — must be multiple of 4
// frag_F:  44 floats matching FragUniforms layout in fill.wgsl

export fn gpuFill(verts_k: ?K, frag_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const ff = kfp(frag_k) orelse return ki(0);
  if (kn(frag_k) != 44) return ki(0);

  var fu: render.FragUniforms = undefined;
  for (0..11) |i| fu.frag[i] = .{ ff[i*4], ff[i*4+1], ff[i*4+2], ff[i*4+3] };

  const n_verts: usize = @intCast(@divTrunc(vn, 4));
  const verts_slice = @as([*]const render.Vertex, @ptrCast(@alignCast(vf)))[0..n_verts];
  r.draw(verts_slice, fu) catch {};
  return ki(0);
}

// ── gpu_tess ──────────────────────────────────────────────────────────────────
//
// pts_F: flat f32 [x0,y0,x1,y1,...] polygon
// Returns flat f32 [x,y,u,v,...] triangle vertices (u=0.5, v=1.0)

export fn gpuTess(pts_k: ?K) callconv(.c) ?K {
  const pf = kfp(pts_k) orelse return ki(0);
  const pn = kn(pts_k);
  if (pn < 6) return ki(0);

  const n: usize = @as(usize, @intCast(pn)) / 2;
  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  const contour = alloc.alloc(tri.Pt, n) catch return ki(0);
  defer alloc.free(contour);
  for (0..n) |i| contour[i] = .{ .x = pf[i * 2], .y = pf[i * 2 + 1] };

  var out = std.ArrayList(tri.Pt).initCapacity(alloc, 64) catch return ki(0);
  defer out.deinit(alloc);

  const contours = [1]tri.Contour{.{ .pts = contour }};
  tri.triangulate(alloc, &contours, &out) catch return ki(0);

  const n_out = out.items.len;
  const result_k = KF(@intCast(n_out * 4)) orelse return ki(0);
  const rf = kfp(result_k) orelse { ku(result_k); return ki(0); };
  for (out.items, 0..) |p, i| {
    rf[i * 4 + 0] = p.x;
    rf[i * 4 + 1] = p.y;
    rf[i * 4 + 2] = 0.5;
    rf[i * 4 + 3] = 1.0;
  }
  return result_k;
}

// ── Window helpers ────────────────────────────────────────────────────────────

fn getFramebufferSize(window: *const anyopaque) [2]u32 {
  var w: i32 = 0;
  var h: i32 = 0;
  zglfw.getFramebufferSize(@constCast(@ptrCast(@alignCast(window))), &w, &h);
  return .{ @intCast(w), @intCast(h) };
}

fn getWindowSize(window: *const anyopaque) [2]u32 {
  var w: i32 = 0;
  var h: i32 = 0;
  zglfw.getWindowSize(@constCast(@ptrCast(@alignCast(window))), &w, &h);
  return .{ @intCast(w), @intCast(h) };
}

fn getTime() f64 { return zglfw.getTime(); }

extern fn glfwGetCocoaWindow(window: *anyopaque) ?*anyopaque;
fn getCocoaWindow(window: *const anyopaque) callconv(.c) ?*anyopaque {
  return glfwGetCocoaWindow(@constCast(window));
}

fn createPipeline(device: wgpu.Device, bgl: wgpu.BindGroupLayout) !wgpu.RenderPipeline {
  const fill_wgsl = @embedFile("fill.wgsl");
  var buf: [fill_wgsl.len + 1]u8 = undefined;
  @memcpy(buf[0..fill_wgsl.len], fill_wgsl);
  buf[fill_wgsl.len] = 0;
  const shader_module = zgpu.createWgslShaderModule(device, buf[0..fill_wgsl.len :0], "fill");
  defer shader_module.release();

  const pipeline_layout = device.createPipelineLayout(.{
    .bind_group_layout_count = 1,
    .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl},
  });
  defer pipeline_layout.release();

  const vtx_attrs = [_]wgpu.VertexAttribute{
    .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
    .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
  };
  const vtx_bufs = [_]wgpu.VertexBufferLayout{.{
    .array_stride    = 16,
    .attribute_count = vtx_attrs.len,
    .attributes      = &vtx_attrs,
  }};
  const color_targets = [_]wgpu.ColorTargetState{.{
    .format     = zgpu.GraphicsContext.swapchain_format,
    .write_mask = wgpu.ColorWriteMask.all,
    .blend      = &wgpu.BlendState{
      .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
      .alpha = .{ .operation = .add, .src_factor = .one,       .dst_factor = .one_minus_src_alpha },
    },
  }};
  return device.createRenderPipeline(.{
    .layout   = pipeline_layout,
    .vertex   = .{
      .module = shader_module, .entry_point = "vs_main",
      .buffer_count = vtx_bufs.len, .buffers = &vtx_bufs,
    },
    .primitive = .{ .topology = .triangle_list },
    .fragment  = &wgpu.FragmentState{
      .module = shader_module, .entry_point = "fs_main",
      .target_count = color_targets.len, .targets = &color_targets,
    },
  });
}

// ── gpu_run ───────────────────────────────────────────────────────────────────
//
// loop_fn: K lambda called each frame with a props dict
// config:  optional float list [width; height] (default 800×600)
// Returns 0 on clean exit, -1 on error.

export fn gpuRun(loop_k: ?K, config_k: ?K) callconv(.c) ?K {
  const loop_fn = loop_k orelse return ki(0);

  var win_w: i32 = 800;
  var win_h: i32 = 600;
  if (config_k) |cfg| {
    if (kfp(cfg)) |cf| {
      if (kn(cfg) >= 2) { win_w = @intFromFloat(cf[0]); win_h = @intFromFloat(cf[1]); }
    }
  }

  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  zglfw.init() catch return ki(-1);
  defer zglfw.terminate();
  zglfw.windowHint(zglfw.ClientAPI, zglfw.NoAPI);
  zglfw.windowHint(zglfw.CocoaRetinaFramebuffer, 1);

  const window = zglfw.createWindow(win_w, win_h, "ink", null, null) catch return ki(-1);
  defer zglfw.destroyWindow(window);

  const gctx = zgpu.GraphicsContext.create(alloc, .{
    .window              = window,
    .fn_getTime          = getTime,
    .fn_getFramebufferSize = getFramebufferSize,
    .fn_getCocoaWindow   = getCocoaWindow,
  }, .{}) catch return ki(-1);
  defer gctx.destroy(alloc);

  const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
    zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
    zgpu.bufferEntry(1, .{ .fragment = true }, .uniform, false, 0),
    .{ .binding = 2, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
    zgpu.samplerEntry(3, .{ .fragment = true }, .filtering),
    .{ .binding = 4, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
    zgpu.samplerEntry(5, .{ .fragment = true }, .filtering),
  };
  const bgl = gctx.device.createBindGroupLayout(.{
    .label = "gpu_ext bgl", .entry_count = bgl_entries.len, .entries = &bgl_entries,
  });
  defer bgl.release();

  const pipeline = createPipeline(gctx.device, bgl) catch return ki(-1);
  defer pipeline.release();

  const renderer = Renderer.init(alloc, gctx.device, gctx.queue, pipeline, bgl, 2_000_000) catch return ki(-1);
  defer renderer.deinit();

  const start_time = zglfw.getTime();

  while (!zglfw.windowShouldClose(window)) {
    zglfw.pollEvents();

    const fb = getFramebufferSize(window);
    if (fb[0] == 0 or fb[1] == 0) { zgpu.wgpuDeviceTick(); continue; }

    const fw: f32 = @floatFromInt(fb[0]);
    const fh: f32 = @floatFromInt(fb[1]);

    const ws = getWindowSize(window);
    const dpr_x: f64 = if (ws[0] > 0) @as(f64, @floatFromInt(fb[0])) / @as(f64, @floatFromInt(ws[0])) else 1.0;
    const dpr_y: f64 = if (ws[1] > 0) @as(f64, @floatFromInt(fb[1])) / @as(f64, @floatFromInt(ws[1])) else 1.0;

    const swapchain_view = gctx.swapchain.getCurrentTextureView();
    defer swapchain_view.release();
    const encoder = gctx.device.createCommandEncoder(.{ .label = "frame" });
    defer encoder.release();

    const pass = encoder.beginRenderPass(.{
      .color_attachment_count = 1,
      .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
        .view        = swapchain_view,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .load_op     = .clear,
        .store_op    = .store,
      }},
    });

    g_renderer = renderer;
    defer g_renderer = null;

    var mx: f64 = 0;
    var my: f64 = 0;
    zglfw.getCursorPos(window, &mx, &my);
    const t: f32 = @floatCast(zglfw.getTime() - start_time);

    // Build props dict and call loop_fn
    const keys = [5][*:0]const u8{ "width", "height", "mx", "my", "time" };
    const v_w = kf(fw); const v_h = kf(fh);
    const v_mx = kf(@floatCast(mx * dpr_x)); const v_my = kf(@floatCast(my * dpr_y));
    const v_t = kf(t);
    const vals = [5]?K{ v_w, v_h, v_mx, v_my, v_t };

    if (k_make_dict(5, &keys, &vals)) |pk| {
      const result = k_call(loop_fn, pk);
      ku(result);
      ku(pk);
    }
    ku(v_w); ku(v_h); ku(v_mx); ku(v_my); ku(v_t);

    renderer.flush(pass, fw, fh) catch {};
    pass.release();

    const cmd = encoder.finish(.{});
    defer cmd.release();
    gctx.queue.submit(&[_]wgpu.CommandBuffer{cmd});
    _ = gctx.present();
    gctx.device.tick();
  }

  return ki(0);
}

// WebGPU SPIRV descriptor (not in zgpu bindings — defined manually from Dawn C API).
const ShaderModuleSPIRVDescriptor = extern struct {
    chain: wgpu.ChainedStruct,
    code_size: u32,
    code: [*]const u32,
};

// ── gpuSpirv ──────────────────────────────────────────────────────────────────
//
// words_k: int list — SPIR-V binary (output of compShader in spirv.k)
// _:       unused (ink 2: requires 2-arg functions)
// Returns a negative shader handle (< 0) for use with gpuFillShader.
// Must be called inside the gpuRun frame callback (needs active renderer).

export fn gpuSpirv(words_k: ?K, _: ?K) callconv(.c) ?K {
    const r = g_renderer orelse return ki(0);
    const ip = kip(words_k) orelse return ki(0);
    const n = kn(words_k);
    if (n < 5) return ki(0);

    const words: [*]const u32 = @ptrCast(@alignCast(ip));

    // Vertex stage: use fill.wgsl vs_main (outputs ftcoord at @location(0)).
    const fill_wgsl = @embedFile("fill.wgsl");
    const vert_z = r.allocator.dupeZ(u8, fill_wgsl) catch return ki(0);
    defer r.allocator.free(vert_z);
    const vert_module = zgpu.createWgslShaderModule(r.device, vert_z, "vert");
    defer vert_module.release();

    // Fragment stage: caller-supplied SPIR-V binary.
    const spirv_desc = ShaderModuleSPIRVDescriptor{
        .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
        .code_size = @intCast(n),
        .code = words,
    };
    const frag_module = r.device.createShaderModule(.{
        .next_in_chain = @ptrCast(&spirv_desc),
    });
    defer frag_module.release();

    const color_targets = [_]wgpu.ColorTargetState{.{
        .format     = zgpu.GraphicsContext.swapchain_format,
        .write_mask = wgpu.ColorWriteMask.all,
        .blend      = &wgpu.BlendState{
            .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .operation = .add, .src_factor = .one,       .dst_factor = .one_minus_src_alpha },
        },
    }};
    const vtx_attrs = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
    };
    const vtx_bufs = [_]wgpu.VertexBufferLayout{.{
        .array_stride = 16, .attribute_count = vtx_attrs.len, .attributes = &vtx_attrs,
    }};
    // Reuse the renderer's bind_group_layout: vs_main reads group 0 binding 0 (view);
    // the SPIR-V fragment shader declares no resources but extra bindings are allowed.
    const layout = r.device.createPipelineLayout(.{
        .bind_group_layout_count = 1,
        .bind_group_layouts = &[_]wgpu.BindGroupLayout{r.bind_group_layout},
    });
    defer layout.release();
    const pipeline = r.device.createRenderPipeline(.{
        .layout  = layout,
        .vertex  = .{ .module = vert_module, .entry_point = "vs_main",
                      .buffer_count = vtx_bufs.len, .buffers = &vtx_bufs },
        .primitive = .{ .topology = .triangle_list },
        .fragment = &wgpu.FragmentState{
            .module = frag_module, .entry_point = "main",
            .target_count = color_targets.len, .targets = &color_targets,
        },
    });
    // Negative handle signals "spirv pipeline, no bind group" to flush()
    r.spirv_pipelines.append(r.allocator, pipeline) catch return ki(0);
    return ki(-@as(i32, @intCast(r.spirv_pipelines.items.len)));
}

// ── gpuFillShader ─────────────────────────────────────────────────────────────
//
// verts_k: flat f32 array [x,y,u,v,...] — same layout as gpuFill
// shader_k: int scalar — handle returned by gpuSpirv

export fn gpuFillShader(verts_k: ?K, shader_k: ?K) callconv(.c) ?K {
    const r = g_renderer orelse return ki(0);
    const vf = kfp(verts_k) orelse return ki(0);
    const vn = kn(verts_k);
    const shader: i32 = ki_val(shader_k);
    if (shader == 0) return ki(0);

    const n_verts: usize = @intCast(@divTrunc(vn, 4));
    const verts_slice = @as([*]const render.Vertex, @ptrCast(@alignCast(vf)))[0..n_verts];
    r.drawShader(verts_slice, shader) catch {};
    return ki(0);
}

// ── gpuCompute ────────────────────────────────────────────────────────────────
//
// words_k:  int list — SPIR-V compute binary (output of compCompute in spirv.k)
// input_k:  float list — input data for the shader (binding 0)
// Returns a new float list with the per-element results (binding 1).
// Must be called inside a gpuRun frame callback (needs active renderer for device/queue).
//
// The compute shader is expected to:
//   - read from binding 0 (StorageBuffer, f32 array)
//   - write to binding 1 (StorageBuffer, f32 array)
//   - use workgroup size 64 (as generated by compCompute)

fn computeMapCallback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
    const done: *bool = @ptrCast(@alignCast(userdata.?));
    done.* = (status == .success);
}

export fn gpuCompute(words_k: ?K, input_k: ?K) callconv(.c) ?K {
    const r = g_renderer orelse return ki(0);
    const ip = kip(words_k) orelse return ki(0);
    const n_words = kn(words_k);
    if (n_words < 5) return ki(0);
    const fp = kfp(input_k) orelse return ki(0);
    const n_input = kn(input_k);
    if (n_input <= 0) return ki(0);
    const n: usize = @intCast(n_input);

    const words: [*]const u32 = @ptrCast(@alignCast(ip));
    const byte_size: u64 = @intCast(n * @sizeOf(f32));

    // SPIR-V compute shader module
    const spirv_desc = ShaderModuleSPIRVDescriptor{
        .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
        .code_size = @intCast(n_words),
        .code = words,
    };
    const cs_module = r.device.createShaderModule(.{
        .next_in_chain = @ptrCast(&spirv_desc),
    });
    defer cs_module.release();

    // Bind group layout: binding 0 = input (read-write storage), binding 1 = output
    const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
        .{ .binding = 1, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
    };
    const bgl = r.device.createBindGroupLayout(.{
        .entry_count = bgl_entries.len,
        .entries = &bgl_entries,
    });
    defer bgl.release();

    const pl_layout = r.device.createPipelineLayout(.{
        .bind_group_layout_count = 1,
        .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl},
    });
    defer pl_layout.release();

    const pipeline = r.device.createComputePipeline(.{
        .layout = pl_layout,
        .compute = .{ .module = cs_module, .entry_point = "main" },
    });
    defer pipeline.release();

    // Input buffer: upload caller data
    const input_buf = r.device.createBuffer(.{
        .label = "compute_in",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = byte_size,
        .mapped_at_creation = .false,
    });
    defer input_buf.release();

    // Output buffer: shader writes here, then we copy to staging
    const output_buf = r.device.createBuffer(.{
        .label = "compute_out",
        .usage = .{ .storage = true, .copy_src = true },
        .size = byte_size,
        .mapped_at_creation = .false,
    });
    defer output_buf.release();

    // Staging buffer: CPU-readable copy of the output
    const staging_buf = r.device.createBuffer(.{
        .label = "compute_stage",
        .usage = .{ .map_read = true, .copy_dst = true },
        .size = byte_size,
        .mapped_at_creation = .false,
    });
    defer staging_buf.release();

    r.queue.writeBuffer(input_buf, 0, f32, fp[0..n]);

    const bg_entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = input_buf,  .size = byte_size },
        .{ .binding = 1, .buffer = output_buf, .size = byte_size },
    };
    const bg = r.device.createBindGroup(.{
        .layout = bgl,
        .entry_count = bg_entries.len,
        .entries = &bg_entries,
    });
    defer bg.release();

    const encoder = r.device.createCommandEncoder(.{ .label = "compute" });
    defer encoder.release();

    {
        const pass = encoder.beginComputePass(null);
        defer pass.release();
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bg, null);
        const workgroups: u32 = @intCast((n + 63) / 64);
        pass.dispatchWorkgroups(workgroups, 1, 1);
        pass.end();
    }
    encoder.copyBufferToBuffer(output_buf, 0, staging_buf, 0, byte_size);

    const cmd = encoder.finish(.{});
    defer cmd.release();
    r.queue.submit(&[_]wgpu.CommandBuffer{cmd});

    // Synchronous readback: spin until mapped
    var done: bool = false;
    staging_buf.mapAsync(.{ .read = true }, 0, byte_size, computeMapCallback, &done);
    while (!done) r.device.tick();

    const result_k = KF(@intCast(n)) orelse { staging_buf.unmap(); return ki(0); };
    const rf = kfp(result_k) orelse { ku(result_k); staging_buf.unmap(); return ki(0); };
    if (staging_buf.getConstMappedRange(f32, 0, n)) |data| @memcpy(rf[0..n], data);
    staging_buf.unmap();

    return result_k;
}

export fn terse_init(reg: *anyopaque) callconv(.c) void {
    _ = reg;
    g_api = .{
        .k_call      = lookupFn(*const fn (K, K) callconv(.c) ?K, "k_call")           orelse return,
        .k_make_dict = lookupFn(*const fn (i32, [*]const [*:0]const u8, [*]const ?K) callconv(.c) ?K, "k_make_dict") orelse return,
        .kf          = lookupFn(*const fn (f32) callconv(.c) ?K, "kf")                 orelse return,
        .ki          = lookupFn(*const fn (i32) callconv(.c) ?K, "ki")                 orelse return,
        .kn          = lookupFn(*const fn (?K) callconv(.c) i32, "kn")                 orelse return,
        .kfp         = lookupFn(*const fn (?K) callconv(.c) ?[*]f32, "kfp")            orelse return,
        .kip         = lookupFn(*const fn (?K) callconv(.c) ?[*]i32, "kip")            orelse return,
        .ki_val      = lookupFn(*const fn (?K) callconv(.c) i32, "ki_val")             orelse return,
        .KF          = lookupFn(*const fn (i32) callconv(.c) ?K, "KF")                 orelse return,
        .ku          = lookupFn(*const fn (?K) callconv(.c) void, "ku")                 orelse return,
    };
}

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
// Zig 0.16's std no longer exposes getenv; call libc directly.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn envStr(name: [*:0]const u8) ?[]const u8 {
  return std.mem.span(getenv(name) orelse return null);
}
fn envInt(name: [*:0]const u8) ?i64 {
  return std.fmt.parseInt(i64, envStr(name) orelse return null, 10) catch null;
}
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
  kcp:         *const fn (?K) callconv(.c) ?[*]u8,
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
fn kcp(x: ?K) ?[*]u8    { return g_api.?.kcp(x); }
fn ki_val(x: ?K) i32    { return g_api.?.ki_val(x); }
fn KF(n: i32) ?K         { return g_api.?.KF(n); }
fn ku(x: ?K) void        { g_api.?.ku(x); }
fn k_call(f: K, a: K) ?K { return g_api.?.k_call(f, a); }
fn k_make_dict(n: i32, keys: [*]const [*:0]const u8, vals: [*]const ?K) ?K {
  return g_api.?.k_make_dict(n, keys, vals);
}

// ── Frame-local renderer (set while the frame callback executes) ───────────────

var g_renderer: ?*Renderer = null;

// ── Input state (written by GLFW callbacks, read each frame) ──────────────────

var g_key_w: bool = false;
var g_key_a: bool = false;
var g_key_s: bool = false;
var g_key_d: bool = false;
var g_scroll: f64 = 0.0;

fn keyCb(_: *zglfw.Window, key: c_int, _: c_int, action: c_int, _: c_int) callconv(.c) void {
  const down = (action != zglfw.Release);
  switch (key) {
    zglfw.KeyW => g_key_w = down,
    zglfw.KeyA => g_key_a = down,
    zglfw.KeyS => g_key_s = down,
    zglfw.KeyD => g_key_d = down,
    else => {},
  }
}

fn scrollCb(_: *zglfw.Window, _: f64, yoffset: f64) callconv(.c) void {
  g_scroll += yoffset;
}

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
// pts_F: flat f32 [x0,y0,x1,y1,...] polygon. Multiple contours (e.g. a glyph
// outline with counters) may be packed into one array separated by a NaN x/y
// pair; holes are then resolved by signed area. A single contour with no NaN
// behaves exactly as before, so existing callers are unaffected.
// Returns flat f32 [x,y,u,v,...] triangle vertices (u=0.5, v=1.0)

export fn gpuTess(pts_k: ?K) callconv(.c) ?K {
  const pf = kfp(pts_k) orelse return ki(0);
  const pn = kn(pts_k);
  if (pn < 6) return ki(0);

  const npair: usize = @as(usize, @intCast(pn)) / 2;
  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  // Split the flat point stream into contours on NaN-pair separators.
  var contours = std.ArrayList(tri.Contour).initCapacity(alloc, 4) catch return ki(0);
  defer {
    for (contours.items) |c| alloc.free(c.pts);
    contours.deinit(alloc);
  }
  var cur = std.ArrayList(tri.Pt).initCapacity(alloc, 32) catch return ki(0);
  defer cur.deinit(alloc);
  for (0..npair) |i| {
    const x = pf[i * 2];
    const y = pf[i * 2 + 1];
    if (std.math.isNan(x) or std.math.isNan(y)) {
      if (cur.items.len >= 3) {
        const slice = alloc.dupe(tri.Pt, cur.items) catch return ki(0);
        contours.append(alloc, .{ .pts = slice }) catch return ki(0);
      }
      cur.clearRetainingCapacity();
    } else {
      cur.append(alloc, .{ .x = x, .y = y }) catch return ki(0);
    }
  }
  if (cur.items.len >= 3) {
    const slice = alloc.dupe(tri.Pt, cur.items) catch return ki(0);
    contours.append(alloc, .{ .pts = slice }) catch return ki(0);
  }

  var out = std.ArrayList(tri.Pt).initCapacity(alloc, 64) catch return ki(0);
  defer out.deinit(alloc);

  tri.triangulate(alloc, contours.items, &out) catch return ki(0);

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
  // `ink -size WxH` overrides the script-supplied window size.
  if (envStr("INK_SIZE")) |s| {
    if (std.mem.indexOfScalar(u8, s, 'x')) |xi| {
      win_w = std.fmt.parseInt(i32, s[0..xi], 10) catch win_w;
      win_h = std.fmt.parseInt(i32, s[xi + 1 ..], 10) catch win_h;
    }
  }

  var da = std.heap.DebugAllocator(.{}).init;
  defer _ = da.deinit();
  const alloc = da.allocator();

  zglfw.init() catch return ki(-1);
  defer zglfw.terminate();
  zglfw.windowHint(zglfw.ClientAPI, zglfw.NoAPI);
  zglfw.windowHint(zglfw.CocoaRetinaFramebuffer, 1);
  // `ink -unfocus` sets INK_UNFOCUS=1 so the window opens without stealing
  // keyboard focus — handy for watch loops that recreate the window on save.
  if (getenv("INK_UNFOCUS") != null) {
    zglfw.windowHint(zglfw.Focused, 0);      // don't steal focus on creation
    zglfw.windowHint(zglfw.FocusOnShow, 0);  // don't steal focus when shown
  }
  // `ink -top` keeps the window above all others (always-on-top).
  if (getenv("INK_TOP") != null) zglfw.windowHint(zglfw.Floating, 1);
  // `ink -monitor N` places the window on monitor N (0-based). Create it hidden
  // so we can position it before it appears — no flash on the wrong screen.
  const mon = envInt("INK_MONITOR");
  if (mon != null) zglfw.windowHint(zglfw.Visible, 0);

  const window = zglfw.createWindow(win_w, win_h, "ink", null, null) catch return ki(-1);
  defer zglfw.destroyWindow(window);

  if (mon) |mi| {
    var count: c_int = 0;
    if (zglfw.getMonitors(&count)) |ms| {
      const idx: usize = if (mi < 0) 0 else @intCast(mi);
      if (idx < @as(usize, @intCast(count))) {
        var mx: c_int = 0;
        var my: c_int = 0;
        zglfw.getMonitorPos(ms[idx], &mx, &my);
        var px = mx;
        var py = my;
        if (zglfw.getVideoMode(ms[idx])) |vmode| { // center on the monitor
          px = mx + @divTrunc(@as(c_int, @intCast(vmode.width)) - @as(c_int, @intCast(win_w)), 2);
          py = my + @divTrunc(@as(c_int, @intCast(vmode.height)) - @as(c_int, @intCast(win_h)), 2);
        }
        zglfw.setWindowPos(window, px, py);
      }
    }
    zglfw.showWindow(window); // FocusOnShow=0 (with -unfocus) keeps focus put
  }

  _ = zglfw.setKeyCallback(window, keyCb);
  _ = zglfw.setScrollCallback(window, scrollCb);

  const gctx = zgpu.GraphicsContext.create(alloc, .{
  .window              = window,
  .fn_getTime          = getTime,
  .fn_getFramebufferSize = getFramebufferSize,
  .fn_getCocoaWindow   = getCocoaWindow,
  }, .{}) catch return ki(-1);
  defer gctx.destroy(alloc);

  gctx.device.setUncapturedErrorCallback(struct {
  fn cb(typ: wgpu.ErrorType, msg: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("[Dawn error] type={} msg={s}\n", .{ typ, msg orelse "(null)" });
  }
  }.cb, null);
  gctx.device.setDeviceLostCallback(struct {
  fn cb(reason: wgpu.DeviceLostReason, msg: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    std.debug.print("[Dawn device lost] reason={} msg={s}\n", .{ reason, msg orelse "(null)" });
  }
  }.cb, null);

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

  // Depth texture: created/resized lazily each time the framebuffer size changes.
  var depth_tex_opt: ?wgpu.Texture = null;
  var depth_view_opt: ?wgpu.TextureView = null;
  var depth_fb: [2]u32 = .{ 0, 0 };
  defer {
  if (depth_view_opt) |dv| dv.release();
  if (depth_tex_opt) |dt| dt.release();
  }

  const start_time = zglfw.getTime();

  while (!zglfw.windowShouldClose(window)) {
  zglfw.pollEvents();

  const fb = getFramebufferSize(window);
  if (fb[0] == 0 or fb[1] == 0) { zgpu.wgpuDeviceTick(); continue; }

  // Recreate depth texture whenever framebuffer size changes.
  if (fb[0] != depth_fb[0] or fb[1] != depth_fb[1]) {
    if (depth_view_opt) |dv| dv.release();
    if (depth_tex_opt) |dt| dt.release();
    const dt = gctx.device.createTexture(.{
    .label = "depth",
    .usage = .{ .render_attachment = true },
    .size  = .{ .width = fb[0], .height = fb[1], .depth_or_array_layers = 1 },
    .format = .depth24_plus,
    });
    depth_tex_opt = dt;
    depth_view_opt = dt.createView(.{});
    depth_fb = fb;
  }

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
  const prop_keys = [11][*:0]const u8{ "width", "height", "mx", "my", "time", "kw", "ka", "ks", "kd", "scroll", "rmb" };
  const v_w = kf(fw); const v_h = kf(fh);
  const v_mx = kf(@floatCast(mx * dpr_x)); const v_my = kf(@floatCast(my * dpr_y));
  const v_t = kf(t);
  const v_kw = kf(if (g_key_w) 1.0 else 0.0);
  const v_ka = kf(if (g_key_a) 1.0 else 0.0);
  const v_ks = kf(if (g_key_s) 1.0 else 0.0);
  const v_kd = kf(if (g_key_d) 1.0 else 0.0);
  const v_sc = kf(@floatCast(g_scroll));
  g_scroll = 0.0;
  const rmb_state = zglfw.getMouseButton(window, zglfw.MouseButtonRight);
  const v_rmb = kf(if (rmb_state == zglfw.Press) 1.0 else 0.0);
  const prop_vals = [11]?K{ v_w, v_h, v_mx, v_my, v_t, v_kw, v_ka, v_ks, v_kd, v_sc, v_rmb };

  if (k_make_dict(11, &prop_keys, &prop_vals)) |pk| {
    const result = k_call(loop_fn, pk);
    ku(result);
    ku(pk);
  }
  ku(v_w); ku(v_h); ku(v_mx); ku(v_my); ku(v_t);
  ku(v_kw); ku(v_ka); ku(v_ks); ku(v_kd); ku(v_sc); ku(v_rmb);

  renderer.flush(pass, fw, fh, t) catch {};
  pass.release();

  // 3-D mesh pass — runs after the 2-D layer, loads colour, adds depth.
  if (depth_view_opt) |depth_view| {
    renderer.flushMeshes(encoder, swapchain_view, depth_view) catch {};
  }

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

// ── gpuCompute2 ─────────────────────────────────────────────────────────────────
//
// Two-input element-wise compute (output of compCompute2 in spirv.k):
//   binding 0 = input1 (StorageBuffer), binding 2 = input2, binding 1 = output.
// in1_k, in2_k: equal-length float lists. Returns a float list of per-element results.
export fn gpuCompute2(words_k: ?K, in1_k: ?K, in2_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const ip = kip(words_k) orelse return ki(0);
  const n_words = kn(words_k);
  if (n_words < 5) return ki(0);
  const fp1 = kfp(in1_k) orelse return ki(0);
  const fp2 = kfp(in2_k) orelse return ki(0);
  const n_input = kn(in1_k);
  if (n_input <= 0) return ki(0);
  if (kn(in2_k) != n_input) return ki(0); // both inputs must be the same length
  const n: usize = @intCast(n_input);
  const words: [*]const u32 = @ptrCast(@alignCast(ip));
  const byte_size: u64 = @intCast(n * @sizeOf(f32));

  const spirv_desc = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(n_words),
    .code = words,
  };
  const cs_module = r.device.createShaderModule(.{ .next_in_chain = @ptrCast(&spirv_desc) });
  defer cs_module.release();

  // binding 0 = input1, binding 1 = output, binding 2 = input2
  const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
    .{ .binding = 0, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
    .{ .binding = 1, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
    .{ .binding = 2, .visibility = .{ .compute = true }, .buffer = .{ .binding_type = .storage } },
  };
  const bgl = r.device.createBindGroupLayout(.{ .entry_count = bgl_entries.len, .entries = &bgl_entries });
  defer bgl.release();
  const pl_layout = r.device.createPipelineLayout(.{ .bind_group_layout_count = 1, .bind_group_layouts = &[_]wgpu.BindGroupLayout{bgl} });
  defer pl_layout.release();
  const pipeline = r.device.createComputePipeline(.{ .layout = pl_layout, .compute = .{ .module = cs_module, .entry_point = "main" } });
  defer pipeline.release();

  const in1_buf = r.device.createBuffer(.{ .label = "compute2_in1", .usage = .{ .storage = true, .copy_dst = true }, .size = byte_size, .mapped_at_creation = .false });
  defer in1_buf.release();
  const in2_buf = r.device.createBuffer(.{ .label = "compute2_in2", .usage = .{ .storage = true, .copy_dst = true }, .size = byte_size, .mapped_at_creation = .false });
  defer in2_buf.release();
  const output_buf = r.device.createBuffer(.{ .label = "compute2_out", .usage = .{ .storage = true, .copy_src = true }, .size = byte_size, .mapped_at_creation = .false });
  defer output_buf.release();
  const staging_buf = r.device.createBuffer(.{ .label = "compute2_stage", .usage = .{ .map_read = true, .copy_dst = true }, .size = byte_size, .mapped_at_creation = .false });
  defer staging_buf.release();

  r.queue.writeBuffer(in1_buf, 0, f32, fp1[0..n]);
  r.queue.writeBuffer(in2_buf, 0, f32, fp2[0..n]);

  const bg_entries = [_]wgpu.BindGroupEntry{
    .{ .binding = 0, .buffer = in1_buf, .size = byte_size },
    .{ .binding = 1, .buffer = output_buf, .size = byte_size },
    .{ .binding = 2, .buffer = in2_buf, .size = byte_size },
  };
  const bg = r.device.createBindGroup(.{ .layout = bgl, .entry_count = bg_entries.len, .entries = &bg_entries });
  defer bg.release();

  const encoder = r.device.createCommandEncoder(.{ .label = "compute2" });
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

  var done: bool = false;
  staging_buf.mapAsync(.{ .read = true }, 0, byte_size, computeMapCallback, &done);
  while (!done) r.device.tick();

  const result_k = KF(@intCast(n)) orelse { staging_buf.unmap(); return ki(0); };
  const rf = kfp(result_k) orelse { ku(result_k); staging_buf.unmap(); return ki(0); };
  if (staging_buf.getConstMappedRange(f32, 0, n)) |data| @memcpy(rf[0..n], data);
  staging_buf.unmap();
  return result_k;
}

// Derive a mesh vertex-buffer layout from a SPIR-V vertex shader by scanning its
// Input variables. Relies on the fixed input-pointer type IDs assigned in
// lib/gpu/spirv.k (PinF32=10, PinV2=14, PinV4=12, PinV3=18) and on input
// Locations being contiguous from 0. Fills `out` and returns count + stride.
const MeshLayout = struct { count: usize, stride_floats: usize };
fn meshVtxLayout(words: []const u32, out: *[16]wgpu.VertexAttribute) MeshLayout {
  var dec_id: [16]u32 = undefined;
  var dec_loc: [16]u32 = undefined;
  var ndec: usize = 0;
  var in_id: [16]u32 = undefined;
  var in_comp: [16]u32 = undefined;
  var nin: usize = 0;

  var i: usize = 5; // skip 5-word header
  while (i < words.len) {
    const w0 = words[i];
    const wc: usize = w0 >> 16;
    const op: u32 = w0 & 0xffff;
    if (wc == 0) break;
    if (op == 71 and i + 3 < words.len and words[i + 2] == 30) { // OpDecorate Location
      if (ndec < 16) { dec_id[ndec] = words[i + 1]; dec_loc[ndec] = words[i + 3]; ndec += 1; }
    } else if (op == 59 and i + 3 < words.len and words[i + 3] == 1) { // OpVariable, storage Input
      const comp: u32 = switch (words[i + 1]) { 10 => 1, 14 => 2, 18 => 3, 12 => 4, else => 0 };
      if (comp > 0 and nin < 16) { in_id[nin] = words[i + 2]; in_comp[nin] = comp; nin += 1; }
    }
    i += wc;
  }

  // Order inputs by their Location, then assign packed offsets.
  var offset: u32 = 0;
  var count: usize = 0;
  var loc: u32 = 0;
  while (loc < nin) : (loc += 1) {
    // find the input variable decorated with this location
    var idx: usize = nin;
    var k: usize = 0;
    while (k < nin) : (k += 1) {
      var d: usize = 0;
      while (d < ndec) : (d += 1) {
        if (dec_id[d] == in_id[k] and dec_loc[d] == loc) { idx = k; break; }
      }
      if (idx != nin) break;
    }
    if (idx == nin) break;
    const comp = in_comp[idx];
    out[count] = .{
      .format = switch (comp) { 1 => .float32, 2 => .float32x2, 3 => .float32x3, else => .float32x4 },
      .offset = offset,
      .shader_location = loc,
    };
    offset += comp * @sizeOf(f32);
    count += 1;
  }
  return .{ .count = count, .stride_floats = offset / @sizeOf(f32) };
}

// ── gpuMesh ───────────────────────────────────────────────────────────────────
//
// vtx_k: int list — SPIR-V vertex shader binary (output of VertexShader in spirv.k)
// frg_k: int list — SPIR-V fragment shader binary (output of FragmentShader in spirv.k)
// Returns a non-negative handle for use with gpuDrawMesh.
// Must be called inside the gpuRun frame callback.

export fn gpuMesh(vtx_k: ?K, frg_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vp = kip(vtx_k) orelse return ki(0);
  const vn = kn(vtx_k);
  if (vn < 5) return ki(0);
  const fp = kip(frg_k) orelse return ki(0);
  const fn_ = kn(frg_k);
  if (fn_ < 5) return ki(0);

  const vtx_words: [*]const u32 = @ptrCast(@alignCast(vp));
  const frg_words: [*]const u32 = @ptrCast(@alignCast(fp));

  const spirv_v = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(vn), .code = vtx_words,
  };
  const vtx_mod = r.device.createShaderModule(.{ .next_in_chain = @ptrCast(&spirv_v) });
  defer vtx_mod.release();

  const spirv_f = ShaderModuleSPIRVDescriptor{
    .chain = .{ .next = null, .struct_type = .shader_module_spirv_descriptor },
    .code_size = @intCast(fn_), .code = frg_words,
  };
  const frg_mod = r.device.createShaderModule(.{ .next_in_chain = @ptrCast(&spirv_f) });
  defer frg_mod.release();

  // Derive the vertex attribute layout from the shader's declared inputs, so a
  // mesh can use any vertex format (stride-6 [x y z nx ny nz], the PBR
  // stride-11, …) without a fixed vertex struct.
  var attr_buf: [16]wgpu.VertexAttribute = undefined;
  const layout_info = meshVtxLayout(vtx_words[0..@intCast(vn)], &attr_buf);
  if (layout_info.count == 0) return ki(0);
  const vtx_bufs = [_]wgpu.VertexBufferLayout{.{
    .array_stride = layout_info.stride_floats * @sizeOf(f32),
    .attribute_count = layout_info.count, .attributes = &attr_buf,
  }};
  const color_targets = [_]wgpu.ColorTargetState{.{
    .format     = zgpu.GraphicsContext.swapchain_format,
    .write_mask = wgpu.ColorWriteMask.all,
    .blend = &wgpu.BlendState{
      .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
      .alpha = .{ .operation = .add, .src_factor = .one,       .dst_factor = .one_minus_src_alpha },
    },
  }};
  const depth_state = wgpu.DepthStencilState{
    .format              = .depth24_plus,
    .depth_write_enabled = true,
    .depth_compare       = .less,
  };
  // No uniforms in the mesh shaders — empty pipeline layout.
  const layout = r.device.createPipelineLayout(.{
    .bind_group_layout_count = 0,
    .bind_group_layouts = &[_]wgpu.BindGroupLayout{},
  });
  defer layout.release();

  const pipeline = r.device.createRenderPipeline(.{
    .layout  = layout,
    .vertex  = .{ .module = vtx_mod, .entry_point = "main",
            .buffer_count = vtx_bufs.len, .buffers = &vtx_bufs },
    .primitive    = .{ .topology = .triangle_list, .cull_mode = .none },
    .depth_stencil = &depth_state,
    .fragment = &wgpu.FragmentState{
      .module = frg_mod, .entry_point = "main",
      .target_count = color_targets.len, .targets = &color_targets,
    },
  });
  if (@intFromPtr(pipeline) == 0) return ki(0);
  r.mesh_pipelines.append(r.allocator, pipeline) catch return ki(0);
  r.mesh_strides.append(r.allocator, layout_info.stride_floats) catch return ki(0);
  return ki(@intCast(r.mesh_pipelines.items.len));
}

// ── gpuDrawMesh ───────────────────────────────────────────────────────────────
//
// verts_k: flat f32 array matching the pipeline's vertex layout (the per-vertex
//   stride is whatever the mesh's vertex shader declares; see gpuMesh).
// handle_k: int scalar — handle returned by gpuMesh

export fn gpuDrawMesh(verts_k: ?K, handle_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const vf = kfp(verts_k) orelse return ki(0);
  const vn = kn(verts_k);
  const handle = ki_val(handle_k);
  if (handle <= 0 or handle > r.mesh_strides.items.len) return ki(0);
  const stride = r.mesh_strides.items[@intCast(handle - 1)];
  if (stride == 0 or vn < @as(i32, @intCast(stride))) return ki(0);

  const n_floats: usize = @intCast(@divTrunc(vn, @as(i32, @intCast(stride))) * @as(i32, @intCast(stride)));
  const floats = vf[0..n_floats];
  r.drawMesh(floats, stride, @intCast(handle - 1)) catch {};
  return ki(0);
}

// ── gpuWgsl ───────────────────────────────────────────────────────────────────
//
// source_k: K char array (ink string) containing a complete WGSL module.
//   Must define vs_main and fs_main using the same bind group layout as fill.wgsl.
//   Binding 0 (@group(0) @binding(0)) is ViewUniforms {viewSize, time, _pad}.
// Returns a positive shader handle for use with gpuFillShader.
// Must be called inside the gpuRun frame callback.

export fn gpuWgsl(source_k: ?K) callconv(.c) ?K {
  const r = g_renderer orelse return ki(0);
  const cp = kcp(source_k) orelse return ki(0);
  const n = kn(source_k);
  if (n <= 0) return ki(0);
  const source = cp[0..@intCast(n)];
  const handle = r.createShader(source) catch return ki(0);
  return ki(handle);
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
    .kcp         = lookupFn(*const fn (?K) callconv(.c) ?[*]u8, "kcp")             orelse return,
    .ki_val      = lookupFn(*const fn (?K) callconv(.c) i32, "ki_val")             orelse return,
    .KF          = lookupFn(*const fn (i32) callconv(.c) ?K, "KF")                 orelse return,
    .ku          = lookupFn(*const fn (?K) callconv(.c) void, "ku")                 orelse return,
  };
}

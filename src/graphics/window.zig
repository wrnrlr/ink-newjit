// Minimal GLFW+WebGPU window for standalone graphics demos.
// No dependency on the UI layout system; use src/ui/window.zig (in foliant)
// for the full widget-based event loop.
const std  = @import("std");
const zglfw = @import("zglfw");
const zgpu  = @import("zgpu");
const wgpu  = zgpu.wgpu;
const ink   = @import("ink");

extern fn glfwGetCocoaWindow(window: *anyopaque) ?*anyopaque;

fn getTime() f64 { return zglfw.getTime(); }

fn getFramebufferSize(window: *const anyopaque) [2]u32 {
  var w: i32 = 0;
  var h: i32 = 0;
  zglfw.getFramebufferSize(@constCast(@ptrCast(@alignCast(window))), &w, &h);
  return .{ @intCast(w), @intCast(h) };
}

fn getCocoaWindow(window: *const anyopaque) callconv(.c) ?*anyopaque {
  return glfwGetCocoaWindow(@constCast(window));
}

fn createPipeline(device: wgpu.Device, bgl: wgpu.BindGroupLayout) !wgpu.RenderPipeline {
  const fill_wgsl = @embedFile("shaders/fill.wgsl");
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
      .module       = shader_module,
      .entry_point  = "vs_main",
      .buffer_count = vtx_bufs.len,
      .buffers      = &vtx_bufs,
    },
    .primitive = .{ .topology = .triangle_list },
    .fragment  = &wgpu.FragmentState{
      .module       = shader_module,
      .entry_point  = "fs_main",
      .target_count = color_targets.len,
      .targets      = &color_targets,
    },
  });
}

pub const WindowOptions = struct {
  title:  [:0]const u8 = "Window",
  width:  i32          = 800,
  height: i32          = 600,
};

pub const Frame = struct {
  swapchain_view: wgpu.TextureView,
  encoder:        wgpu.CommandEncoder,
  pass:           wgpu.RenderPassEncoder,
  fw: f32, fh: f32,
  lw: f32, lh: f32,
};

pub const Window = struct {
  window:   *zglfw.Window,
  gctx:     *zgpu.GraphicsContext,
  gx:       *ink.Gx,
  renderer: *ink.Renderer,
  pipeline: wgpu.RenderPipeline,
  bgl:      wgpu.BindGroupLayout,
  drawing:  bool = false,
  allocator: std.mem.Allocator,

  pub fn init(allocator: std.mem.Allocator, options: WindowOptions) !*Window {
    try zglfw.init();
    zglfw.windowHint(zglfw.ClientAPI, zglfw.NoAPI);
    zglfw.windowHint(zglfw.CocoaRetinaFramebuffer, 1);
    const window = try zglfw.createWindow(options.width, options.height, options.title, null, null);
    const gctx = try zgpu.GraphicsContext.create(allocator, .{
      .window              = window,
      .fn_getTime          = getTime,
      .fn_getFramebufferSize = getFramebufferSize,
      .fn_getCocoaWindow   = getCocoaWindow,
    }, .{});
    const bgl_entries = [_]wgpu.BindGroupLayoutEntry{
      zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
      zgpu.bufferEntry(1, .{ .fragment = true }, .uniform, false, 0),
      .{ .binding = 2, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
      zgpu.samplerEntry(3, .{ .fragment = true }, .filtering),
      .{ .binding = 4, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float } },
      zgpu.samplerEntry(5, .{ .fragment = true }, .filtering),
    };
    const bgl = gctx.device.createBindGroupLayout(.{
      .label       = "ink bgl",
      .entry_count = bgl_entries.len,
      .entries     = &bgl_entries,
    });
    const pipeline = try createPipeline(gctx.device, bgl);
    const gx_ptr = try allocator.create(ink.Gx);
    gx_ptr.* = try ink.Gx.init(allocator);
    const renderer = try ink.Renderer.init(allocator, gctx.device, gctx.queue, pipeline, bgl, 2_000_000);
    gx_ptr.setRenderer(renderer);
    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    zglfw.getWindowContentScale(window, &xscale, &yscale);
    gx_ptr.setDpr(xscale);
    ink.setContext(gx_ptr);
    const self = try allocator.create(Window);
    self.* = .{
      .window   = window,
      .gctx     = gctx,
      .gx       = gx_ptr,
      .renderer = renderer,
      .pipeline = pipeline,
      .bgl      = bgl,
      .allocator = allocator,
    };
    return self;
  }

  pub fn running(self: *Window) bool {
    zglfw.pollEvents();
    return !zglfw.windowShouldClose(self.window);
  }

  pub fn beginFrame(self: *Window) !?Frame {
    if (self.drawing) return null;
    self.drawing = true;
    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    zglfw.getWindowContentScale(self.window, &xscale, &yscale);
    self.gx.reset();
    self.gx.setDpr(xscale);
    const fb = getFramebufferSize(self.window);
    if (fb[0] == 0 or fb[1] == 0) {
      zgpu.wgpuDeviceTick();
      self.drawing = false;
      return null;
    }
    const fw: f32 = @floatFromInt(fb[0]);
    const fh: f32 = @floatFromInt(fb[1]);
    const swapchain_view = self.gctx.swapchain.getCurrentTextureView();
    const encoder = self.gctx.device.createCommandEncoder(.{ .label = "frame" });
    const pass = encoder.beginRenderPass(.{
      .color_attachment_count = 1,
      .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
        .view        = swapchain_view,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        .load_op     = .clear,
        .store_op    = .store,
      }},
    });
    return Frame{
      .swapchain_view = swapchain_view,
      .encoder = encoder,
      .pass    = pass,
      .fw = fw, .fh = fh,
      .lw = fw / xscale, .lh = fh / yscale,
    };
  }

  pub fn endFrame(self: *Window, frame: Frame) !void {
    defer self.drawing = false;
    defer frame.swapchain_view.release();
    defer frame.encoder.release();
    try self.renderer.flush(self.gx, frame.pass, frame.fw, frame.fh);
    frame.pass.release();
    var cmd = frame.encoder.finish(.{ .label = "frame cmd" });
    defer cmd.release();
    self.gctx.queue.submit(&.{cmd});
    _ = self.gctx.present();
    self.gctx.device.tick();
  }

  pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
    self.renderer.deinit();
    self.gx.deinit();
    allocator.destroy(self.gx);
    self.bgl.release();
    self.pipeline.release();
    self.gctx.destroy(allocator);
    zglfw.destroyWindow(self.window);
    zglfw.terminate();
    allocator.destroy(self);
  }
};

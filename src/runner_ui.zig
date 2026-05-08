const std = @import("std");
const zgpu = @import("zgpu");
const zglfw = @import("zglfw");
const wgpu = zgpu.wgpu;
const ink = @import("ink");
const VM = @import("runtime/vm.zig").VM;
const value = @import("noun/value.zig");
const call_mod = @import("runtime/call.zig");
const gfx_render = @import("primitive/verb/gfx_render.zig");

const V = value.V;

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

// ── Event queue ───────────────────────────────────────────────────────────────

const EventTag = enum { mousemove, mousedown, mouseup, keydown, keyup, scroll };

const Event = union(EventTag) {
  mousemove: struct { x: f64, y: f64 },
  mousedown: struct { button: i32, x: f64, y: f64 },
  mouseup:   struct { button: i32, x: f64, y: f64 },
  keydown:   struct { key: i32, mods: i32 },
  keyup:     struct { key: i32, mods: i32 },
  scroll:    struct { dx: f64, dy: f64 },
};

var g_events: std.ArrayList(Event) = .empty;
var g_cursor_x: f64 = 0;
var g_cursor_y: f64 = 0;
var g_alloc: std.mem.Allocator = undefined;
var g_animate: bool = false;

fn mouseButtonCb(window: *zglfw.Window, button: i32, action: i32, mods: i32) callconv(.c) void {
  _ = window; _ = mods;
  const ev: Event = if (action == 1)
    .{ .mousedown = .{ .button = button, .x = g_cursor_x, .y = g_cursor_y } }
  else
    .{ .mouseup   = .{ .button = button, .x = g_cursor_x, .y = g_cursor_y } };
  g_events.append(g_alloc, ev) catch {};
}

fn cursorPosCb(window: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
  _ = window;
  g_cursor_x = x;
  g_cursor_y = y;
  g_events.append(g_alloc, .{ .mousemove = .{ .x = x, .y = y } }) catch {};
}

fn keyCb(window: *zglfw.Window, key: i32, scancode: i32, action: i32, mods: i32) callconv(.c) void {
  _ = window; _ = scancode;
  if (action == 2) return; // ignore repeat
  const ev: Event = if (action == 1)
    .{ .keydown = .{ .key = key, .mods = mods } }
  else
    .{ .keyup   = .{ .key = key, .mods = mods } };
  g_events.append(g_alloc, ev) catch {};
}

fn scrollCb(window: *zglfw.Window, dx: f64, dy: f64) callconv(.c) void {
  _ = window;
  g_events.append(g_alloc, .{ .scroll = .{ .dx = dx, .dy = dy } }) catch {};
}

fn dispatchResult(vm: *VM, result: V) void {
  _ = gfx_render.dispatchGfx(vm, result, &g_animate);
}

const App = struct {
  window: *zglfw.Window,
  gctx: *zgpu.GraphicsContext,
  gx: *ink.Gx,
  renderer: *ink.Renderer,
  vm: *VM,
  loop_fn: V,
  drawing: bool = false,

  fn frame(self: *App) !void {
    if (self.drawing) return;
    self.drawing = true;
    defer self.drawing = false;
    g_animate = false;

    while (true) {
      var xscale: f32 = 1.0;
      var yscale: f32 = 1.0;
      zglfw.getWindowContentScale(self.window, &xscale, &yscale);
      self.gx.reset();
      self.gx.setDpr(xscale);

      const fb = getFramebufferSize(self.window);
      if (fb[0] == 0 or fb[1] == 0) { zgpu.wgpuDeviceTick(); return; }
      const fw: f32 = @floatFromInt(fb[0]);
      const fh: f32 = @floatFromInt(fb[1]);

      const alloc = self.vm.alloc;

      const prop_keys = try V.Symbols(alloc, &[_]u32{
        try self.vm.intern("width"),
        try self.vm.intern("height"),
        try self.vm.intern("ppi"),
        try self.vm.intern("time"),
        try self.vm.intern("mx"),
        try self.vm.intern("my"),
      });
      errdefer prop_keys.deinit(alloc);
      const prop_vals = try V.Values(alloc, &[_]V{
        V{ .f = fw / xscale },
        V{ .f = fh / yscale },
        V{ .f = xscale * 96.0 },
        V{ .f = @floatCast(zglfw.getTime()) },
        V{ .f = @floatCast(g_cursor_x / xscale) },
        V{ .f = @floatCast(g_cursor_y / yscale) },
      });
      errdefer prop_vals.deinit(alloc);
      const props = V{ .m = try value.Dict.init(alloc, prop_keys, prop_vals) };
      defer props.deinit(alloc);

      const events_v = try buildEvents(self.vm);
      defer events_v.deinit(alloc);
      g_events.clearRetainingCapacity();

      var fc = call_mod.Call{ .vm = self.vm };
      var loop_args = [_]V{ V{ .i = 1 }, props.ref(), events_v.ref() };
      defer for (&loop_args) |*a| a.deinit(alloc);
      const result = fc.apply(self.loop_fn, &loop_args, false) catch |err| {
        std.debug.print("fc.apply error: {s}\n", .{@errorName(err)});
        return err;
      };
      defer result.deinit(alloc);

      const swapchain_view = self.gctx.swapchain.getCurrentTextureView();
      defer swapchain_view.release();

      const encoder = self.gctx.device.createCommandEncoder(.{ .label = "runner" });
      defer encoder.release();

      {
        const pass = encoder.beginRenderPass(.{
          .color_attachment_count = 1,
          .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
            .view         = swapchain_view,
            .clear_value  = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1.0 },
            .load_op      = .clear,
            .store_op     = .store,
          }},
        });
        defer pass.release();

        dispatchResult(self.vm, result);

        try self.renderer.flush(self.gx, pass, fw, fh);
      }

      var cmd = encoder.finish(.{ .label = "runner cmd" });
      defer cmd.release();
      self.gctx.submit(&.{cmd});

      if (self.gctx.present() == .swap_chain_resized) continue;
      zgpu.wgpuDeviceTick();
      break;
    }
  }
};

fn buildEvents(vm: *VM) !V {
  const alloc = vm.alloc;
  const evs = g_events.items;
  if (evs.len == 0) return V.Values(alloc, &.{});

  const list = try value.N(V).init(alloc, evs.len);
  @memset(list.slice(), .blank);
  const result = V{ .L = list };
  errdefer result.deinit(alloc);

  for (evs, 0..) |ev, i| {
    list.slice()[i] = switch (ev) {
      .mousemove => |e| blk: {
        const ks = try V.Symbols(alloc, &[_]u32{
          try vm.intern("type"), try vm.intern("x"), try vm.intern("y"),
        });
        errdefer ks.deinit(alloc);
        const vs = try V.Values(alloc, &[_]V{
          V{ .s = try vm.intern("mousemove") }, V{ .f = @floatCast(e.x) }, V{ .f = @floatCast(e.y) },
        });
        errdefer vs.deinit(alloc);
        break :blk V{ .m = try value.Dict.init(alloc, ks, vs) };
      },
      .mousedown => |e| blk: {
        const ks = try V.Symbols(alloc, &[_]u32{
          try vm.intern("type"), try vm.intern("button"), try vm.intern("x"), try vm.intern("y"),
        });
        errdefer ks.deinit(alloc);
        const vs = try V.Values(alloc, &[_]V{
          V{ .s = try vm.intern("mousedown") }, V{ .i = e.button }, V{ .f = @floatCast(e.x) }, V{ .f = @floatCast(e.y) },
        });
        errdefer vs.deinit(alloc);
        break :blk V{ .m = try value.Dict.init(alloc, ks, vs) };
      },
      .mouseup => |e| blk: {
        const ks = try V.Symbols(alloc, &[_]u32{
          try vm.intern("type"), try vm.intern("button"), try vm.intern("x"), try vm.intern("y"),
        });
        errdefer ks.deinit(alloc);
        const vs = try V.Values(alloc, &[_]V{
          V{ .s = try vm.intern("mouseup") }, V{ .i = e.button }, V{ .f = @floatCast(e.x) }, V{ .f = @floatCast(e.y) },
        });
        errdefer vs.deinit(alloc);
        break :blk V{ .m = try value.Dict.init(alloc, ks, vs) };
      },
      .keydown => |e| blk: {
        const ks = try V.Symbols(alloc, &[_]u32{
          try vm.intern("type"), try vm.intern("key"), try vm.intern("mods"),
        });
        errdefer ks.deinit(alloc);
        const vs = try V.Values(alloc, &[_]V{
          V{ .s = try vm.intern("keydown") }, V{ .i = e.key }, V{ .i = e.mods },
        });
        errdefer vs.deinit(alloc);
        break :blk V{ .m = try value.Dict.init(alloc, ks, vs) };
      },
      .keyup => |e| blk: {
        const ks = try V.Symbols(alloc, &[_]u32{
          try vm.intern("type"), try vm.intern("key"), try vm.intern("mods"),
        });
        errdefer ks.deinit(alloc);
        const vs = try V.Values(alloc, &[_]V{
          V{ .s = try vm.intern("keyup") }, V{ .i = e.key }, V{ .i = e.mods },
        });
        errdefer vs.deinit(alloc);
        break :blk V{ .m = try value.Dict.init(alloc, ks, vs) };
      },
      .scroll => |e| blk: {
        const ks = try V.Symbols(alloc, &[_]u32{
          try vm.intern("type"), try vm.intern("dx"), try vm.intern("dy"),
        });
        errdefer ks.deinit(alloc);
        const vs = try V.Values(alloc, &[_]V{
          V{ .s = try vm.intern("scroll") }, V{ .f = @floatCast(e.dx) }, V{ .f = @floatCast(e.dy) },
        });
        errdefer vs.deinit(alloc);
        break :blk V{ .m = try value.Dict.init(alloc, ks, vs) };
      },
    };
  }

  return result;
}

fn createPipeline(device: wgpu.Device, bgl: wgpu.BindGroupLayout) !wgpu.RenderPipeline {
  const fill_wgsl = @embedFile("graphics/shaders/fill.wgsl");

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
      .color = .{ .operation = .add, .src_factor = .src_alpha,     .dst_factor = .one_minus_src_alpha },
      .alpha = .{ .operation = .add, .src_factor = .one,           .dst_factor = .one_minus_src_alpha },
    },
  }};

  return device.createRenderPipeline(.{
    .layout   = pipeline_layout,
    .vertex   = .{
      .module      = shader_module,
      .entry_point = "vs_main",
      .buffer_count = vtx_bufs.len,
      .buffers     = &vtx_bufs,
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

pub fn run(vm: *VM, loop_fn: V, allocator: std.mem.Allocator) !void {
  g_alloc = allocator;
  defer g_events.deinit(allocator);

  try zglfw.init();
  defer zglfw.terminate();

  zglfw.windowHint(zglfw.ClientAPI, zglfw.NoAPI);
  zglfw.windowHint(zglfw.CocoaRetinaFramebuffer, 1);

  const window = try zglfw.createWindow(800, 600, "ink", null, null);
  defer zglfw.destroyWindow(window);

  const gctx = try zgpu.GraphicsContext.create(allocator, .{
    .window              = window,
    .fn_getTime          = getTime,
    .fn_getFramebufferSize = getFramebufferSize,
    .fn_getCocoaWindow   = getCocoaWindow,
  }, .{});
  defer gctx.destroy(allocator);

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
  defer bgl.release();

  const pipeline = try createPipeline(gctx.device, bgl);
  defer pipeline.release();

  var gx = try ink.Gx.init(allocator);
  defer gx.deinit();
  const renderer = try ink.Renderer.init(allocator, gctx.device, gctx.queue, pipeline, bgl, 100_000);
  defer renderer.deinit();
  gx.setRenderer(renderer);

  var xscale: f32 = 1.0;
  var yscale: f32 = 1.0;
  zglfw.getWindowContentScale(window, &xscale, &yscale);
  gx.setDpr(xscale);
  ink.setContext(&gx);
  _ = ink.createFont("sans", "/System/Library/Fonts/Helvetica.ttc");

  var app = App{
    .window   = window,
    .gctx     = gctx,
    .gx       = &gx,
    .renderer = renderer,
    .vm       = vm,
    .loop_fn  = loop_fn,
  };

  zglfw.setWindowUserPointer(window, &app);

  _ = zglfw.setWindowRefreshCallback(window, struct {
    fn cb(w: *zglfw.Window) callconv(.c) void {
      const a: *App = @ptrCast(@alignCast(zglfw.getWindowUserPointer(w).?));
      a.frame() catch |err| std.debug.print("frame error: {s}\n", .{@errorName(err)});
    }
  }.cb);
  _ = zglfw.setFramebufferSizeCallback(window, struct {
    fn cb(w: *zglfw.Window, _: i32, _: i32) callconv(.c) void {
      const a: *App = @ptrCast(@alignCast(zglfw.getWindowUserPointer(w).?));
      a.frame() catch |err| std.debug.print("frame error: {s}\n", .{@errorName(err)});
    }
  }.cb);
  _ = zglfw.setWindowContentScaleCallback(window, struct {
    fn cb(w: *zglfw.Window, _: f32, _: f32) callconv(.c) void {
      const a: *App = @ptrCast(@alignCast(zglfw.getWindowUserPointer(w).?));
      a.frame() catch |err| std.debug.print("frame error: {s}\n", .{@errorName(err)});
    }
  }.cb);
  _ = zglfw.setMouseButtonCallback(window, mouseButtonCb);
  _ = zglfw.setCursorPosCallback(window,   cursorPosCb);
  _ = zglfw.setKeyCallback(window,         keyCb);
  _ = zglfw.setScrollCallback(window,      scrollCb);

  try app.frame();

  while (!zglfw.windowShouldClose(window) and zglfw.getKey(window, 256) == 0) {
    if (g_animate) zglfw.pollEvents() else zglfw.waitEvents();
    if (g_events.items.len > 0 or g_animate) try app.frame();
  }
}

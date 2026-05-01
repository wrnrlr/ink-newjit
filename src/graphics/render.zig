const std = @import("std");
const paint = @import("paint.zig");
const ink = @import("draw.zig");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Gx = paint.Gx;
const Paint = ink.Paint;

pub const Vertex = extern struct {
  x: f32, y: f32, u: f32, v: f32,
};

pub const DrawKind = enum { fill, stroke, triangles };

pub const ViewUniforms = extern struct {
  viewSize: [2]f32,
  _pad: [2]f32 = .{ 0, 0 },
};

pub const FragUniforms = extern struct {
  frag: [11][4]f32,
};

pub const DrawCall = struct {
  kind: DrawKind,
  offset: usize,
  count: usize,
  frag: FragUniforms,
  image: ink.Img,
  shader: i32 = 0,
};


pub const Renderer = struct {
  allocator: Alloc,
  device: wgpu.Device,
  queue: wgpu.Queue,
  pipeline: wgpu.RenderPipeline,
  bind_group_layout: wgpu.BindGroupLayout,
  view_buffer: wgpu.Buffer,
  frag_buffer: wgpu.Buffer,
  vertex_buffer: wgpu.Buffer,
  dummy_view: wgpu.TextureView,
  dummy_sampler: wgpu.Sampler,
  max_verts: usize,
  draw_calls: ArrayList(DrawCall),
  custom_pipelines: ArrayList(wgpu.RenderPipeline),

  pub fn init(allocator: Alloc, device: wgpu.Device, queue: wgpu.Queue, pipeline: wgpu.RenderPipeline, bgl: wgpu.BindGroupLayout, max_verts: usize) !*Renderer {
    const self = try allocator.create(Renderer);
    self.* = .{
      .allocator = allocator,
      .device = device,
      .queue = queue,
      .pipeline = pipeline,
      .bind_group_layout = bgl,
      .draw_calls = try ArrayList(DrawCall).initCapacity(allocator, 0),
      .custom_pipelines = try ArrayList(wgpu.RenderPipeline).initCapacity(allocator, 0),
      .view_buffer = device.createBuffer(.{
        .label = "view uniform buffer",
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = @sizeOf(ViewUniforms),
        .mapped_at_creation = .false,
      }),
      .frag_buffer = device.createBuffer(.{
        .label = "frag uniform buffer",
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = 1024 * 256,
        .mapped_at_creation = .false,
      }),
      .vertex_buffer = device.createBuffer(.{
        .label = "vertex buffer",
        .usage = .{ .vertex = true, .copy_dst = true },
        .size = max_verts * @sizeOf(Vertex),
        .mapped_at_creation = .false,
      }),
      .dummy_view = blk: {
        const tex = device.createTexture(.{
          .label = "dummy texture",
          .size = .{ .width = 1, .height = 1, .depth_or_array_layers = 1 },
          .usage = .{ .texture_binding = true },
          .format = .rgba8_unorm,
        });
        const view = tex.createView(.{});
        tex.release();
        break :blk view;
      },
      .dummy_sampler = device.createSampler(.{ .label = "dummy sampler" }),
      .max_verts = max_verts,
    };
    return self;
  }

  pub fn deinit(self: *Renderer) void {
    self.view_buffer.release();
    self.frag_buffer.release();
    self.vertex_buffer.release();
    self.dummy_view.release();
    self.dummy_sampler.release();
    for (self.custom_pipelines.items) |p| p.release();
    self.custom_pipelines.deinit(self.allocator);
    self.draw_calls.deinit(self.allocator);
    self.allocator.destroy(self);
  }

  pub fn draw(self: *Renderer, gx: *Gx, kind: DrawKind, offset: usize, count: usize, p: Paint) !void {
    const state = gx.getState();
    var frag = FragUniforms{ .frag = [_][4]f32{[_]f32{0} ** 4} ** 11 };

    // Scissor
    var scMat = [_]f32{0} ** 6;
    var scExt = [2]f32{ 1, 1 };
    var scScale = [2]f32{ 1, 1 };
    if (state.scissor.extent[0] < 0) {
      paint.xformIdentity(&scMat);
      scExt = .{ 1e10, 1e10 };
      scScale = .{ 1, 1 };
    } else {
      _ = paint.xformInverse(&scMat, state.scissor.xform);
      scExt = state.scissor.extent;
      scScale[0] = @sqrt(state.scissor.xform[0] * state.scissor.xform[0] + state.scissor.xform[2] * state.scissor.xform[2]) / gx.dist_tol;
      scScale[1] = @sqrt(state.scissor.xform[1] * state.scissor.xform[1] + state.scissor.xform[3] * state.scissor.xform[3]) / gx.dist_tol;
    }

    // Scissor matrix: 6-element xform → 3x3 columns for WGSL mat3x3
    // xform layout: [a00,a10, a01,a11, tx,ty]
    // col0=(a00,a10,0), col1=(a01,a11,0), col2=(tx,ty,1)
    frag.frag[0] = .{ scMat[0], scMat[1], 0, 0 };
    frag.frag[1] = .{ scMat[2], scMat[3], 0, 0 };
    frag.frag[2] = .{ scMat[4], scMat[5], 1, 0 };

    // Paint matrix
    var paintMat = state.xform;
    paint.xformMultiply(&paintMat, p.xform);
    var invMat = [_]f32{0} ** 6;
    _ = paint.xformInverse(&invMat, paintMat);
    frag.frag[3] = .{ invMat[0], invMat[1], 0, 0 };
    frag.frag[4] = .{ invMat[2], invMat[3], 0, 0 };
    frag.frag[5] = .{ invMat[4], invMat[5], 1, 0 };

    // Colors
    frag.frag[6] = p.inner.toF32x4();
    frag.frag[7] = p.outer.toF32x4();

    frag.frag[8] = .{ scExt[0], scExt[1], scScale[0], scScale[1] };
    frag.frag[9] = .{ p.extent[0], p.extent[1], p.radius, p.feather };

    const ptype: f32 = if (p.image.handle != 0) 1.0 else 0.0;
    frag.frag[10] = .{ 0, ptype, p.blur[0], p.blur[1] };

    var shader: i32 = 0;
    var image = p.image;
    if (image.handle < 0) {
      shader = -image.handle;
      image.handle = 0;
    }

    try self.draw_calls.append(self.allocator, .{
      .kind = kind,
      .offset = offset,
      .count = count,
      .frag = frag,
      .image = image,
      .shader = shader,
    });
  }

  pub fn flush(self: *Renderer, gx: *Gx, pass: wgpu.RenderPassEncoder, width: f32, height: f32) !void {
    defer pass.end();
    defer {
      self.draw_calls.clearRetainingCapacity();
      gx.cache.verts.clearRetainingCapacity();
    }
    if (gx.cache.verts.items.len == 0) return;

    // TODO: What about Dp vs Sp
    // const view = ViewUniforms{ .viewSize = .{ width / gx.dpr, height / gx.dpr } };
    const view = ViewUniforms{ .viewSize = .{ width, height } };
    self.queue.writeBuffer(self.view_buffer, 0, ViewUniforms, &[_]ViewUniforms{view});

    const verts = gx.cache.verts.items;
    const write_count = @min(verts.len, self.max_verts);
    self.queue.writeBuffer(self.vertex_buffer, 0, Vertex, verts[0..write_count]);

    pass.setVertexBuffer(0, self.vertex_buffer, 0, write_count * @sizeOf(Vertex));

    for (self.draw_calls.items, 0..) |dc, i| {
      const frag_offset = i * 256;
      self.queue.writeBuffer(self.frag_buffer, frag_offset, FragUniforms, &[_]FragUniforms{dc.frag});

      const bind_entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .buffer = self.view_buffer, .size = @sizeOf(ViewUniforms) },
        .{ .binding = 1, .buffer = self.frag_buffer, .offset = frag_offset, .size = @sizeOf(FragUniforms) },
        .{ .binding = 2, .texture_view = self.dummy_view, .size = 0 },
        .{ .binding = 3, .sampler = self.dummy_sampler, .size = 0 },
        .{ .binding = 4, .texture_view = self.dummy_view, .size = 0 },
        .{ .binding = 5, .sampler = self.dummy_sampler, .size = 0 },
      };
      const bind_group = self.device.createBindGroup(.{
        .layout = self.bind_group_layout,
        .entry_count = bind_entries.len,
        .entries = &bind_entries,
      });

      if (dc.shader > 0 and dc.shader <= self.custom_pipelines.items.len) {
        pass.setPipeline(self.custom_pipelines.items[@intCast(dc.shader - 1)]);
      } else {
        pass.setPipeline(self.pipeline);
      }
      pass.setBindGroup(0, bind_group, null);
      pass.draw(@intCast(dc.count), 1, @intCast(dc.offset), 0);
      bind_group.release();
    }
  }

  pub fn createShader(self: *Renderer, source: []const u8) !i32 {
    const source_z = try self.allocator.dupeZ(u8, source);
    defer self.allocator.free(source_z);

    const shader_module = zgpu.createWgslShaderModule(self.device, source_z, "custom shader");
    defer shader_module.release();

    const color_targets = [_]wgpu.ColorTargetState{.{
      .format = zgpu.GraphicsContext.swapchain_format,
      .write_mask = wgpu.ColorWriteMask.all,
      .blend = &wgpu.BlendState{
        .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
        .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
      },
    }};

    const vertex_attributes = [_]wgpu.VertexAttribute{
      .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
      .{ .format = .float32x2, .offset = @offsetOf(Vertex, "u"), .shader_location = 1 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
      .array_stride = @sizeOf(Vertex),
      .attribute_count = vertex_attributes.len,
      .attributes = &vertex_attributes,
    }};

    const pipeline_layout = self.device.createPipelineLayout(.{
      .label = "custom pipeline layout",
      .bind_group_layout_count = 1,
      .bind_group_layouts = &[_]wgpu.BindGroupLayout{self.bind_group_layout},
    });
    defer pipeline_layout.release();

    const pipeline = self.device.createRenderPipeline(.{
      .label = "custom shader pipeline",
      .layout = pipeline_layout,
      .vertex = .{
        .module = shader_module,
        .entry_point = "vs_main",
        .buffer_count = vertex_buffers.len,
        .buffers = &vertex_buffers,
      },
      .primitive = .{
        .topology = .triangle_list,
        .front_face = .ccw,
        .cull_mode = .none,
      },
      .fragment = &wgpu.FragmentState{
        .module = shader_module,
        .entry_point = "fs_main",
        .target_count = color_targets.len,
        .targets = &color_targets,
      },
    });

    try self.custom_pipelines.append(self.allocator, pipeline);
    return @intCast(self.custom_pipelines.items.len);
  }
};

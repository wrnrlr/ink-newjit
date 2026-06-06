const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Vertex = extern struct {
  x: f32, y: f32, u: f32, v: f32,
};

pub const ViewUniforms = extern struct {
  viewSize: [2]f32,
  _pad: [2]f32 = .{ 0, 0 },
};

// Matches fill.wgsl FragUniforms: 11 vec4 rows.
// Layout (row indices):
//   [0-2]  scissor matrix columns (mat3x3)
//   [3-5]  paint matrix inverse columns (mat3x3)
//   [6]    inner color (RGBA)
//   [7]    outer color (RGBA)
//   [8]    scissor extent [ex,ey], scissor scale [sx,sy]
//   [9]    paint extent [ex,ey], radius, feather
//   [10]   texType, type (0=gradient,1=image,2=stencil,3=tris,4=blur), blurDir [bx,by]
pub const FragUniforms = extern struct {
  frag: [11][4]f32,
};

// No-scissor, solid-color identity frag uniforms at the given RGBA.
pub fn solidFrag(r: f32, g: f32, b: f32, a: f32) FragUniforms {
  var f = FragUniforms{ .frag = [_][4]f32{.{ 0, 0, 0, 0 }} ** 11 };
  f.frag[0] = .{ 1, 0, 0, 0 }; // scissor col0
  f.frag[1] = .{ 0, 1, 0, 0 }; // scissor col1
  f.frag[2] = .{ 0, 0, 1, 0 }; // scissor col2
  f.frag[3] = .{ 1, 0, 0, 0 }; // paint col0 (identity inverse)
  f.frag[4] = .{ 0, 1, 0, 0 }; // paint col1
  f.frag[5] = .{ 0, 0, 1, 0 }; // paint col2
  f.frag[6] = .{ r, g, b, a }; // inner color
  f.frag[7] = .{ r, g, b, a }; // outer color (same → solid)
  f.frag[8] = .{ 1e10, 1e10, 1, 1 }; // no scissor
  // frag[9].x = extent.x = 0 → shader takes solid-color branch (ext.x < 0.5)
  f.frag[10] = .{ 0, 0, 0, 0 }; // type=0 (gradient path), texType=0
  return f;
}

pub const DrawCall = struct {
  offset: usize,
  count: usize,
  frag: FragUniforms,
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
  verts: ArrayList(Vertex),
  draw_calls: ArrayList(DrawCall),
  custom_pipelines: ArrayList(wgpu.RenderPipeline),

  pub fn init(
    allocator: Alloc,
    device: wgpu.Device,
    queue: wgpu.Queue,
    pipeline: wgpu.RenderPipeline,
    bgl: wgpu.BindGroupLayout,
    max_verts: usize,
  ) !*Renderer {
    const self = try allocator.create(Renderer);
    self.* = .{
      .allocator = allocator,
      .device = device,
      .queue = queue,
      .pipeline = pipeline,
      .bind_group_layout = bgl,
      .verts = try ArrayList(Vertex).initCapacity(allocator, 4096),
      .draw_calls = try ArrayList(DrawCall).initCapacity(allocator, 64),
      .custom_pipelines = try ArrayList(wgpu.RenderPipeline).initCapacity(allocator, 4),
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
    self.verts.deinit(self.allocator);
    self.allocator.destroy(self);
  }

  // Queue a triangle-list draw call. Verts are appended to the internal buffer;
  // offset/count are recorded for the GPU draw command issued in flush().
  pub fn draw(self: *Renderer, verts: []const Vertex, frag: FragUniforms) !void {
    const offset = self.verts.items.len;
    try self.verts.appendSlice(verts);
    try self.draw_calls.append(.{
      .offset = offset,
      .count = verts.len,
      .frag = frag,
    });
  }

  // Submit all queued draw calls to the render pass and clear the buffers.
  pub fn flush(self: *Renderer, pass: wgpu.RenderPassEncoder, width: f32, height: f32) !void {
    defer pass.end();
    defer {
      self.draw_calls.clearRetainingCapacity();
      self.verts.clearRetainingCapacity();
    }
    if (self.verts.items.len == 0) return;

    const view = ViewUniforms{ .viewSize = .{ width, height } };
    self.queue.writeBuffer(self.view_buffer, 0, ViewUniforms, &[_]ViewUniforms{view});

    const verts = self.verts.items;
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
      defer bind_group.release();

      if (dc.shader > 0 and dc.shader <= self.custom_pipelines.items.len) {
        pass.setPipeline(self.custom_pipelines.items[@intCast(dc.shader - 1)]);
      } else {
        pass.setPipeline(self.pipeline);
      }
      pass.setBindGroup(0, bind_group, null);
      pass.draw(@intCast(dc.count), 1, @intCast(dc.offset), 0);
    }
  }

  // Compile a custom WGSL shader (must have vs_main/fs_main + same bind group layout).
  // Returns a shader ID > 0 to pass in draw calls via DrawCall.shader.
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
      .primitive = .{ .topology = .triangle_list, .front_face = .ccw, .cull_mode = .none },
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

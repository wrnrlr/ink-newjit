const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const Alloc = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Vertex = extern struct {
  x: f32, y: f32, u: f32, v: f32,
};

// Capacity of the shared mesh vertex buffer, in f32s (~3M floats ≈ 12 MB).
pub const MESH_BUFFER_FLOATS: usize = 3_000_000;

// Mesh vertices are stored as raw f32. The per-vertex layout (stride and
// attributes) is whatever the mesh pipeline's vertex shader declares — see
// gpuMesh, which derives it from the SPIR-V — so meshes are not tied to one
// fixed vertex struct.
pub const MeshCall = struct {
  offset: usize, // f32 offset into mesh_verts
  count: usize,  // vertex count
  stride: usize, // f32s per vertex
  pipeline_idx: usize,
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
  spirv_pipelines: ArrayList(wgpu.RenderPipeline),
  // 3-D mesh rendering
  mesh_vertex_buffer: wgpu.Buffer,
  mesh_verts: ArrayList(f32),
  mesh_calls: ArrayList(MeshCall),
  mesh_pipelines: ArrayList(wgpu.RenderPipeline),
  mesh_strides: ArrayList(usize), // f32s per vertex, parallel to mesh_pipelines

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
    .spirv_pipelines = try ArrayList(wgpu.RenderPipeline).initCapacity(allocator, 4),
    .mesh_verts = try ArrayList(f32).initCapacity(allocator, 4096),
    .mesh_calls = try ArrayList(MeshCall).initCapacity(allocator, 16),
    .mesh_pipelines = try ArrayList(wgpu.RenderPipeline).initCapacity(allocator, 4),
    .mesh_strides = try ArrayList(usize).initCapacity(allocator, 4),
    .mesh_vertex_buffer = device.createBuffer(.{
    .label = "mesh vertex buffer",
    .usage = .{ .vertex = true, .copy_dst = true },
    .size = MESH_BUFFER_FLOATS * @sizeOf(f32),
    .mapped_at_creation = .false,
    }),
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
  for (self.spirv_pipelines.items) |p| p.release();
  self.spirv_pipelines.deinit(self.allocator);
  for (self.mesh_pipelines.items) |p| { if (@intFromPtr(p) != 0) p.release(); }
  self.mesh_pipelines.deinit(self.allocator);
  self.mesh_strides.deinit(self.allocator);
  self.mesh_vertex_buffer.release();
  self.mesh_calls.deinit(self.allocator);
  self.mesh_verts.deinit(self.allocator);
  self.draw_calls.deinit(self.allocator);
  self.verts.deinit(self.allocator);
  self.allocator.destroy(self);
  }

  // Queue a triangle-list draw call. Verts are appended to the internal buffer;
  // offset/count are recorded for the GPU draw command issued in flush().
  pub fn draw(self: *Renderer, verts: []const Vertex, frag: FragUniforms) !void {
  const offset = self.verts.items.len;
  try self.verts.appendSlice(self.allocator, verts);
  try self.draw_calls.append(self.allocator, .{
    .offset = offset,
    .count = verts.len,
    .frag = frag,
  });
  }

  // Queue a draw call using a custom SPIR-V pipeline (handle from createSpirvFrag).
  pub fn drawShader(self: *Renderer, verts: []const Vertex, shader: i32) !void {
  const offset = self.verts.items.len;
  try self.verts.appendSlice(self.allocator, verts);
  try self.draw_calls.append(self.allocator, .{
    .offset = offset,
    .count = verts.len,
    .frag = std.mem.zeroes(FragUniforms),
    .shader = shader,
  });
  }

  // Submit all queued draw calls to the render pass and clear the buffers.
  pub fn flush(self: *Renderer, pass: wgpu.RenderPassEncoder, width: f32, height: f32, time: f32) !void {
  defer pass.end();
  defer {
    self.draw_calls.clearRetainingCapacity();
    self.verts.clearRetainingCapacity();
  }
  if (self.verts.items.len == 0) return;

  const view = ViewUniforms{ .viewSize = .{ width, height }, ._pad = .{ time, 0 } };
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
    if (dc.shader < 0) {
    // SPIR-V pipeline: negative handle indexes into spirv_pipelines
    const idx: usize = @intCast((-dc.shader) - 1);
    if (idx < self.spirv_pipelines.items.len) {
      pass.setPipeline(self.spirv_pipelines.items[idx]);
    }
    } else if (dc.shader > 0 and dc.shader <= self.custom_pipelines.items.len) {
    pass.setPipeline(self.custom_pipelines.items[@intCast(dc.shader - 1)]);
    } else {
    pass.setPipeline(self.pipeline);
    }
    pass.setBindGroup(0, bind_group, null);
    pass.draw(@intCast(dc.count), 1, @intCast(dc.offset), 0);
  }
  }

  // Queue a 3-D mesh draw call. `verts` is raw f32 vertex data; `stride` is the
  // number of f32s per vertex (pipeline-specific, see gpuMesh).
  pub fn drawMesh(self: *Renderer, verts: []const f32, stride: usize, pipeline_idx: usize) !void {
  if (stride == 0) return;
  const offset = self.mesh_verts.items.len;
  try self.mesh_verts.appendSlice(self.allocator, verts);
  try self.mesh_calls.append(self.allocator, .{
    .offset = offset, .count = verts.len / stride, .stride = stride, .pipeline_idx = pipeline_idx,
  });
  }

  // Submit all mesh draw calls in a new render pass that loads the existing colour
  // layer and adds depth-tested geometry on top.
  pub fn flushMeshes(
  self: *Renderer,
  encoder: wgpu.CommandEncoder,
  color_view: wgpu.TextureView,
  depth_view: wgpu.TextureView,
  ) !void {
  defer {
    self.mesh_calls.clearRetainingCapacity();
    self.mesh_verts.clearRetainingCapacity();
  }
  if (self.mesh_verts.items.len == 0) return;

  const verts = self.mesh_verts.items;
  const write_count = @min(verts.len, MESH_BUFFER_FLOATS);
  self.queue.writeBuffer(self.mesh_vertex_buffer, 0, f32, verts[0..write_count]);

  const depth_att = wgpu.RenderPassDepthStencilAttachment{
    .view             = depth_view,
    .depth_load_op    = .clear,
    .depth_store_op   = .store,
    .depth_clear_value = 1.0,
    .depth_read_only  = .false,
    .stencil_read_only = .true,
  };
  const pass = encoder.beginRenderPass(.{
    .color_attachment_count = 1,
    .color_attachments = &[_]wgpu.RenderPassColorAttachment{.{
    .view     = color_view,
    .load_op  = .load,
    .store_op = .store,
    }},
    .depth_stencil_attachment = &depth_att,
  });
  defer pass.release();
  defer pass.end();

  // Each call may use a different vertex stride, so bind the buffer slice
  // per-call (byte offset/size) and draw from vertex 0 of that slice.
  for (self.mesh_calls.items) |mc| {
    if (mc.pipeline_idx >= self.mesh_pipelines.items.len) continue;
    const end = mc.offset + (mc.count * mc.stride);
    if (end > write_count) continue;
    pass.setPipeline(self.mesh_pipelines.items[mc.pipeline_idx]);
    pass.setVertexBuffer(0, self.mesh_vertex_buffer, mc.offset * @sizeOf(f32), mc.count * mc.stride * @sizeOf(f32));
    pass.draw(@intCast(mc.count), 1, 0, 0);
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

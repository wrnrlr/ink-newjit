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

// Per-draw mesh uniform block: 8 vec4 slots (32 f32s) exposed to the shader as
// @group(0) @binding(0).  Each draw gets a 256-byte-aligned slot in one shared
// buffer; pipelines opt in by declaring a Uniform-storage variable (see gpuMesh).
pub const MESH_UNI_FLOATS: usize = 32;
pub const MESH_UNI_SLOT: usize = 256;
pub const MAX_MESH_UNI_CALLS: usize = 512;

// Instancing: per-frame storage buffer holding every instanced draw's instance
// data (a flat vec4[] per draw, read in-shader via gl_InstanceIndex).  Each draw's
// slice starts on a 64-float (256-byte) boundary for storage-binding alignment.
pub const MESH_INST_FLOATS: usize = 1_000_000;
pub const INST_ALIGN_FLOATS: usize = 64;

// Max textures a single mesh pipeline can sample (bound at @group(1), image k at
// binding k, one shared sampler at binding tex_n).  A per-draw list of texture
// handles rides in the call; -1 slots are unused.
pub const MAX_TEX: usize = 8;
const NO_TEX: [MAX_TEX]i32 = [_]i32{-1} ** MAX_TEX;

// A retained, instanced draw: a geometry (persistent vertex buffer) drawn once
// with instanceCount instances; instance data lives at inst_data[data_off..].
pub const InstCall = struct {
  geom_idx: usize,
  inst_count: u32,
  data_off: usize, // f32 offset into the renderer's inst_data
  data_len: usize, // f32 length of this draw's instance block
  tex: [MAX_TEX]i32 = NO_TEX, // texture handles bound at @group(1) (shared by all instances)
  tex_n: u8 = 0,
};

// A retained, instanced draw whose per-instance data lives in a RESIDENT compute
// buffer (from the resident-compute registry) instead of the per-frame inst_data.
// This is the readback-free path: a GPU solver writes positions into a buffer and
// the vertex shader pulls them straight out — no host round-trip.
pub const ResidentCall = struct {
  geom_idx: usize,
  inst_count: u32,
  buffer: wgpu.Buffer, // vec4[] storage buffer, one slot(s) per instance
  byte_size: u64,
};

// A retained mesh drawn once with a per-draw uniform block (@group(0)) and
// optional textures (@group(1)) — the non-instanced counterpart of InstCall.
// Geometry lives in a persistent buffer (uploadGeom), so only the small uniform
// block is written per frame; the vertex data is never re-uploaded.
pub const GeomCall = struct {
  geom_idx: usize,
  uniform: [MESH_UNI_FLOATS]f32 = [_]f32{0} ** MESH_UNI_FLOATS,
  tex: [MAX_TEX]i32 = NO_TEX,
  tex_n: u8 = 0,
};

// Mesh vertices are stored as raw f32. The per-vertex layout (stride and
// attributes) is whatever the mesh pipeline's vertex shader declares — see
// gpuMesh, which derives it from the SPIR-V — so meshes are not tied to one
// fixed vertex struct.
pub const MeshCall = struct {
  offset: usize, // f32 offset into mesh_verts
  count: usize,  // vertex count
  stride: usize, // f32s per vertex
  pipeline_idx: usize,
  uniform: [MESH_UNI_FLOATS]f32 = [_]f32{0} ** MESH_UNI_FLOATS,
  tex: [MAX_TEX]i32 = NO_TEX, // texture handles bound at @group(1); tex_n = how many
  tex_n: u8 = 0,
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
  mesh_has_uniform: ArrayList(bool), // does pipeline i declare a uniform block? parallel to mesh_pipelines
  mesh_is_instanced: ArrayList(bool), // does pipeline i read an instance storage buffer? parallel to mesh_pipelines
  mesh_has_texture: ArrayList(bool), // does pipeline i sample a texture at @group(1)? parallel to mesh_pipelines
  mesh_tex_n: ArrayList(usize), // how many textures pipeline i samples (parallel to mesh_pipelines)
  mesh_tex_bgls: ArrayList(?wgpu.BindGroupLayout), // per-pipeline @group(1) layout (n textures + 1 sampler), null if none
  mesh_bgl: wgpu.BindGroupLayout, // shared layout for the mesh uniform block (binding 0)
  mesh_uniform_buffer: wgpu.Buffer,
  tex_views: ArrayList(wgpu.TextureView),  // uploaded texture views (see uploadTexture)
  tex_samplers: ArrayList(wgpu.Sampler),   // one sampler per uploaded texture, parallel to tex_views
  // Instancing: retained geometry (persistent vertex buffers) + per-frame instance data
  mesh_inst_bgl: wgpu.BindGroupLayout, // read-only storage buffer (binding 0)
  mesh_inst_buffer: wgpu.Buffer,
  geom_buffers: ArrayList(wgpu.Buffer), // persistent vertex buffers (one per UploadMesh)
  geom_counts: ArrayList(u32),          // vertex count per geometry
  geom_pipeline: ArrayList(usize),      // pipeline index per geometry
  inst_data: ArrayList(f32),            // this frame's instance data (all instanced draws)
  inst_calls: ArrayList(InstCall),
  resident_calls: ArrayList(ResidentCall), // this frame's readback-free instanced draws
  geom_calls: ArrayList(GeomCall),      // this frame's retained uniform+texture draws

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
      .mesh_has_uniform = try ArrayList(bool).initCapacity(allocator, 4),
      .mesh_is_instanced = try ArrayList(bool).initCapacity(allocator, 4),
      .mesh_has_texture = try ArrayList(bool).initCapacity(allocator, 4),
      .mesh_tex_n = try ArrayList(usize).initCapacity(allocator, 4),
      .mesh_tex_bgls = try ArrayList(?wgpu.BindGroupLayout).initCapacity(allocator, 4),
      .tex_views = try ArrayList(wgpu.TextureView).initCapacity(allocator, 4),
      .tex_samplers = try ArrayList(wgpu.Sampler).initCapacity(allocator, 4),
      .mesh_bgl = device.createBindGroupLayout(.{
      .label = "mesh uniform bgl",
      .entry_count = 1,
      .entries = &[_]wgpu.BindGroupLayoutEntry{
        zgpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
      },
      }),
      .mesh_uniform_buffer = device.createBuffer(.{
      .label = "mesh uniform buffer",
      .usage = .{ .uniform = true, .copy_dst = true },
      .size = MAX_MESH_UNI_CALLS * MESH_UNI_SLOT,
      .mapped_at_creation = .false,
      }),
      .mesh_inst_bgl = device.createBindGroupLayout(.{
      .label = "mesh instance bgl",
      .entry_count = 1,
      .entries = &[_]wgpu.BindGroupLayoutEntry{
        zgpu.bufferEntry(0, .{ .vertex = true }, .read_only_storage, false, 0),
      },
      }),
      .mesh_inst_buffer = device.createBuffer(.{
      .label = "mesh instance buffer",
      .usage = .{ .storage = true, .copy_dst = true },
      .size = MESH_INST_FLOATS * @sizeOf(f32),
      .mapped_at_creation = .false,
      }),
      .geom_buffers = try ArrayList(wgpu.Buffer).initCapacity(allocator, 4),
      .geom_counts = try ArrayList(u32).initCapacity(allocator, 4),
      .geom_pipeline = try ArrayList(usize).initCapacity(allocator, 4),
      .inst_data = try ArrayList(f32).initCapacity(allocator, 4096),
      .inst_calls = try ArrayList(InstCall).initCapacity(allocator, 16),
      .resident_calls = try ArrayList(ResidentCall).initCapacity(allocator, 4),
      .geom_calls = try ArrayList(GeomCall).initCapacity(allocator, 16),
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
    self.mesh_has_uniform.deinit(self.allocator);
    self.mesh_is_instanced.deinit(self.allocator);
    self.mesh_has_texture.deinit(self.allocator);
    self.mesh_tex_n.deinit(self.allocator);
    for (self.mesh_tex_bgls.items) |b| if (b) |l| l.release();
    self.mesh_tex_bgls.deinit(self.allocator);
    for (self.tex_views.items) |v| v.release();
    self.tex_views.deinit(self.allocator);
    for (self.tex_samplers.items) |s| s.release();
    self.tex_samplers.deinit(self.allocator);
    self.mesh_bgl.release();
    self.mesh_uniform_buffer.release();
    self.mesh_inst_bgl.release();
    self.mesh_inst_buffer.release();
    for (self.geom_buffers.items) |b| b.release();
    self.geom_buffers.deinit(self.allocator);
    self.geom_counts.deinit(self.allocator);
    self.geom_pipeline.deinit(self.allocator);
    self.inst_data.deinit(self.allocator);
    self.inst_calls.deinit(self.allocator);
    self.resident_calls.deinit(self.allocator);
    self.geom_calls.deinit(self.allocator);
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

  // Pack a slice of texture handles into a fixed [MAX_TEX]i32 + count for a call.
  fn packTex(tex: []const i32) struct { arr: [MAX_TEX]i32, n: u8 } {
    var arr: [MAX_TEX]i32 = NO_TEX;
    const n = @min(tex.len, MAX_TEX);
    var k: usize = 0;
    while (k < n) : (k += 1) arr[k] = tex[k];
    return .{ .arr = arr, .n = @intCast(n) };
  }

  // Build the @group(1) texture bind group for a pipeline: n texture views
  // (bindings 0..n-1) + one shared sampler (binding n, taken from the first
  // texture).  Returns null if any handle is invalid.
  fn makeTexBg(self: *Renderer, bgl: wgpu.BindGroupLayout, tex: []const i32, n: usize) ?wgpu.BindGroup {
    if (n == 0 or n > MAX_TEX) return null;
    var entries: [MAX_TEX + 1]wgpu.BindGroupEntry = undefined;
    var samp: usize = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
      const h = tex[k];
      if (h < 0 or @as(usize, @intCast(h)) >= self.tex_views.items.len) return null;
      const hi: usize = @intCast(h);
      entries[k] = .{ .binding = @intCast(k), .texture_view = self.tex_views.items[hi], .size = 0 };
      if (k == 0) samp = hi;
    }
    entries[n] = .{ .binding = @intCast(n), .sampler = self.tex_samplers.items[samp], .size = 0 };
    return self.device.createBindGroup(.{ .layout = bgl, .entry_count = @intCast(n + 1), .entries = &entries });
  }

  // If pipeline_idx samples textures, build its @group(1) bind group from `tex`
  // (the call's handle array) and set it. Binds the pipeline's declared texture
  // count. Returns the bind group so the caller can release it after the draw.
  fn bindTex(self: *Renderer, pass: wgpu.RenderPassEncoder, pipeline_idx: usize, tex: []const i32) ?wgpu.BindGroup {
    const tn = if (pipeline_idx < self.mesh_tex_n.items.len) self.mesh_tex_n.items[pipeline_idx] else 0;
    if (tn == 0) return null;
    const bgl = if (pipeline_idx < self.mesh_tex_bgls.items.len) self.mesh_tex_bgls.items[pipeline_idx] else null;
    if (bgl) |l| if (self.makeTexBg(l, tex, tn)) |bg| {
      pass.setBindGroup(1, bg, null);
      return bg;
    };
    return null;
  }

  // Queue a 3-D mesh draw call. `verts` is raw f32 vertex data; `stride` is the
  // number of f32s per vertex (pipeline-specific, see gpuMesh). `tex` is the list
  // of texture handles to bind at @group(1).
  pub fn drawMesh(self: *Renderer, verts: []const f32, stride: usize, pipeline_idx: usize, uni: [MESH_UNI_FLOATS]f32, tex: []const i32) !void {
    if (stride == 0) return;
    const offset = self.mesh_verts.items.len;
    try self.mesh_verts.appendSlice(self.allocator, verts);
    const pt = packTex(tex);
    try self.mesh_calls.append(self.allocator, .{
      .offset = offset, .count = verts.len / stride, .stride = stride, .pipeline_idx = pipeline_idx, .uniform = uni, .tex = pt.arr, .tex_n = pt.n,
    });
  }

  // Upload an RGBA8 image to a GPU texture (+ a linear, u-repeat/v-clamp sampler,
  // suited to equirectangular maps) and return its index for drawMesh's tex_idx.
  // `rgba` is width*height*4 bytes, row-major, top-left first.
  pub fn uploadTexture(self: *Renderer, width: u32, height: u32, rgba: []const u8) !usize {
  const tex = self.device.createTexture(.{
    .label = "mesh texture",
    .usage = .{ .texture_binding = true, .copy_dst = true },
    .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
    .format = .rgba8_unorm,
  });
  defer tex.release();
  self.queue.writeTexture(
    .{ .texture = tex, .mip_level = 0, .origin = .{}, .aspect = .all },
    .{ .offset = 0, .bytes_per_row = width * 4, .rows_per_image = height },
    .{ .width = width, .height = height, .depth_or_array_layers = 1 },
    u8,
    rgba,
  );
  const view = tex.createView(.{});
  const sampler = self.device.createSampler(.{
    .label = "mesh sampler",
    .address_mode_u = .repeat,
    .address_mode_v = .clamp_to_edge,
    .mag_filter = .linear,
    .min_filter = .linear,
  });
  try self.tex_views.append(self.allocator, view);
  try self.tex_samplers.append(self.allocator, sampler);
  return self.tex_views.items.len - 1;
  }

  // Upload mesh geometry to a PERSISTENT vertex buffer (retained — uploaded once,
  // not per frame).  Returns a geometry index for drawInstanced.
  pub fn uploadGeom(self: *Renderer, verts: []const f32, stride: usize, pipeline_idx: usize) !usize {
  const buf = self.device.createBuffer(.{
    .label = "geom vertex buffer",
    .usage = .{ .vertex = true, .copy_dst = true },
    .size = verts.len * @sizeOf(f32),
    .mapped_at_creation = .false,
  });
  self.queue.writeBuffer(buf, 0, f32, verts);
  try self.geom_buffers.append(self.allocator, buf);
  try self.geom_counts.append(self.allocator, @intCast(if (stride == 0) 0 else verts.len / stride));
  try self.geom_pipeline.append(self.allocator, pipeline_idx);
  return self.geom_buffers.items.len - 1;
  }

  // Queue an instanced draw of a retained geometry: `data` is the flat vec4[]
  // instance block (inst_count instances × K vec4s).  The block is appended to
  // this frame's instance buffer on a 64-float boundary.
  pub fn queueInstanced(self: *Renderer, geom_idx: usize, inst_count: u32, data: []const f32, tex: []const i32) !void {
  if (geom_idx >= self.geom_buffers.items.len) return;
  // pad to the storage-binding alignment so this block starts 256-byte aligned
  const rem = self.inst_data.items.len % INST_ALIGN_FLOATS;
  if (rem != 0) try self.inst_data.appendNTimes(self.allocator, 0, INST_ALIGN_FLOATS - rem);
  const off = self.inst_data.items.len;
  try self.inst_data.appendSlice(self.allocator, data);
  const pt = packTex(tex);
  try self.inst_calls.append(self.allocator, .{
    .geom_idx = geom_idx, .inst_count = inst_count, .data_off = off, .data_len = data.len, .tex = pt.arr, .tex_n = pt.n,
  });
  }

  // Readback-free instanced draw: bind an already-resident buffer as the per-instance
  // storage source (no upload). `buffer` is a vec4[] holding inst_count slots.
  pub fn queueResidentInstanced(self: *Renderer, geom_idx: usize, inst_count: u32, buffer: wgpu.Buffer, byte_size: u64) !void {
    if (geom_idx >= self.geom_buffers.items.len) return;
    try self.resident_calls.append(self.allocator, .{ .geom_idx = geom_idx, .inst_count = inst_count, .buffer = buffer, .byte_size = byte_size });
  }

  // Queue a draw of a retained geometry with a per-draw uniform block and an
  // optional texture (tex_idx < 0 = none).  The vertex buffer is the persistent
  // one from uploadGeom — nothing but the uniform block is written per frame.
  pub fn queueGeom(self: *Renderer, geom_idx: usize, uni: [MESH_UNI_FLOATS]f32, tex: []const i32) !void {
  if (geom_idx >= self.geom_buffers.items.len) return;
  const pt = packTex(tex);
  try self.geom_calls.append(self.allocator, .{ .geom_idx = geom_idx, .uniform = uni, .tex = pt.arr, .tex_n = pt.n });
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
      self.inst_calls.clearRetainingCapacity();
      self.inst_data.clearRetainingCapacity();
      self.resident_calls.clearRetainingCapacity();
      self.geom_calls.clearRetainingCapacity();
    }
    if (self.mesh_verts.items.len == 0 and self.inst_calls.items.len == 0 and self.resident_calls.items.len == 0 and self.geom_calls.items.len == 0) return;
  
    const verts = self.mesh_verts.items;
    const write_count = @min(verts.len, MESH_BUFFER_FLOATS);
    if (write_count > 0) self.queue.writeBuffer(self.mesh_vertex_buffer, 0, f32, verts[0..write_count]);
  
    // Upload this frame's instance data once (one storage buffer for all instanced draws).
    const inst_n = @min(self.inst_data.items.len, MESH_INST_FLOATS);
    if (inst_n > 0) self.queue.writeBuffer(self.mesh_inst_buffer, 0, f32, self.inst_data.items[0..inst_n]);
  
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
    var uni_call: usize = 0;
    for (self.mesh_calls.items) |mc| {
      if (mc.pipeline_idx >= self.mesh_pipelines.items.len) continue;
      const end = mc.offset + (mc.count * mc.stride);
      if (end > write_count) continue;
      pass.setPipeline(self.mesh_pipelines.items[mc.pipeline_idx]);
      pass.setVertexBuffer(0, self.mesh_vertex_buffer, mc.offset * @sizeOf(f32), mc.count * mc.stride * @sizeOf(f32));
      // Pipelines that declared a uniform block get a per-draw bind group at
      // @group(0); those that sample a texture also get one at @group(1). Shaders
      // with neither keep the empty pipeline layout and draw with no bind group.
      const has_uni = mc.pipeline_idx < self.mesh_has_uniform.items.len and self.mesh_has_uniform.items[mc.pipeline_idx];
      var uni_bg: ?wgpu.BindGroup = null;
      if (has_uni and uni_call < MAX_MESH_UNI_CALLS) {
      const off = uni_call * MESH_UNI_SLOT;
      self.queue.writeBuffer(self.mesh_uniform_buffer, off, f32, mc.uniform[0..]);
      const be = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = self.mesh_uniform_buffer, .offset = off, .size = MESH_UNI_FLOATS * @sizeOf(f32) }};
      uni_bg = self.device.createBindGroup(.{ .layout = self.mesh_bgl, .entry_count = be.len, .entries = &be });
      pass.setBindGroup(0, uni_bg.?, null);
      uni_call += 1;
      }
      defer if (uni_bg) |bg| bg.release();
      const tex_bg = self.bindTex(pass, mc.pipeline_idx, &mc.tex);
      defer if (tex_bg) |bg| bg.release();
      pass.draw(@intCast(mc.count), 1, 0, 0);
    }

    // Retained draws: persistent geometry + per-draw uniform (@group0) + optional
    // texture (@group1).  Same bind groups as the mesh loop, but the vertex buffer
    // is the persistent one, so nothing but the uniform block is written per frame.
    for (self.geom_calls.items) |gc| {
      if (gc.geom_idx >= self.geom_buffers.items.len) continue;
      const pidx = self.geom_pipeline.items[gc.geom_idx];
      if (pidx >= self.mesh_pipelines.items.len) continue;
      const gcount = self.geom_counts.items[gc.geom_idx];
      pass.setPipeline(self.mesh_pipelines.items[pidx]);
      pass.setVertexBuffer(0, self.geom_buffers.items[gc.geom_idx], 0, @as(usize, gcount) * self.mesh_strides.items[pidx] * @sizeOf(f32));
      var uni_bg: ?wgpu.BindGroup = null;
      if (uni_call < MAX_MESH_UNI_CALLS) {
      const off = uni_call * MESH_UNI_SLOT;
      self.queue.writeBuffer(self.mesh_uniform_buffer, off, f32, gc.uniform[0..]);
      const be = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = self.mesh_uniform_buffer, .offset = off, .size = MESH_UNI_FLOATS * @sizeOf(f32) }};
      uni_bg = self.device.createBindGroup(.{ .layout = self.mesh_bgl, .entry_count = be.len, .entries = &be });
      pass.setBindGroup(0, uni_bg.?, null);
      uni_call += 1;
      }
      defer if (uni_bg) |bg| bg.release();
      const tex_bg = self.bindTex(pass, pidx, &gc.tex);
      defer if (tex_bg) |bg| bg.release();
      pass.draw(gcount, 1, 0, 0);
    }

    // Instanced draws: each retained geometry is drawn once with instanceCount
    // instances; the shader reads instance data from the bound storage-buffer slice.
    for (self.inst_calls.items) |ic| {
      if (ic.geom_idx >= self.geom_buffers.items.len) continue;
      if (ic.data_off + ic.data_len > inst_n) continue;
      const pidx = self.geom_pipeline.items[ic.geom_idx];
      if (pidx >= self.mesh_pipelines.items.len) continue;
      pass.setPipeline(self.mesh_pipelines.items[pidx]);
      const gcount = self.geom_counts.items[ic.geom_idx];
      pass.setVertexBuffer(0, self.geom_buffers.items[ic.geom_idx], 0, @as(usize, gcount) * self.mesh_strides.items[pidx] * @sizeOf(f32));
      const be = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = self.mesh_inst_buffer, .offset = ic.data_off * @sizeOf(f32), .size = ic.data_len * @sizeOf(f32) }};
      const bg = self.device.createBindGroup(.{ .layout = self.mesh_inst_bgl, .entry_count = be.len, .entries = &be });
      defer bg.release();
      pass.setBindGroup(0, bg, null);
      // A textured instanced pipeline binds the shared textures at @group(1).
      const tex_bg = self.bindTex(pass, pidx, &ic.tex);
      defer if (tex_bg) |b| b.release();
      pass.draw(gcount, ic.inst_count, 0, 0);
    }

    // Readback-free instanced draws: like the above, but the per-instance storage
    // buffer is a resident compute buffer (the solver's output) — no host upload.
    for (self.resident_calls.items) |rcall| {
      if (rcall.geom_idx >= self.geom_buffers.items.len) continue;
      const pidx = self.geom_pipeline.items[rcall.geom_idx];
      if (pidx >= self.mesh_pipelines.items.len) continue;
      pass.setPipeline(self.mesh_pipelines.items[pidx]);
      const gcount = self.geom_counts.items[rcall.geom_idx];
      pass.setVertexBuffer(0, self.geom_buffers.items[rcall.geom_idx], 0, @as(usize, gcount) * self.mesh_strides.items[pidx] * @sizeOf(f32));
      const be = [_]wgpu.BindGroupEntry{.{ .binding = 0, .buffer = rcall.buffer, .offset = 0, .size = rcall.byte_size }};
      const bg = self.device.createBindGroup(.{ .layout = self.mesh_inst_bgl, .entry_count = be.len, .entries = &be });
      defer bg.release();
      pass.setBindGroup(0, bg, null);
      pass.draw(gcount, rcall.inst_count, 0, 0);
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

// Native WebGPU backend (Dawn).
//
// Single arena buffer + bump allocator + a fixed staging buffer for
// readback. Pipelines compiled lazily and cached. Submitting blocks on
// the device queue via wgpu.Device.tick() polls.
//
// Only this file links Dawn. The rest of the codebase sees gpu.GpuCtx
// (an interface) and never imports zgpu directly.

const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const gpu = @import("gpu");


const Alloc = std.mem.Allocator;

const ARENA_BYTES: u32 = 64 * 1024 * 1024; // 64 MB
const STAGING_BYTES: u32 = 8 * 1024 * 1024; // 8 MB readback ring (single chunk for now)
const MIN_OFFSET_ALIGN: u32 = 256;          // wgpu min storage buffer offset alignment

const ARENA_BUF: gpu.BufferHandle = @enumFromInt(1);

const IOTA_WGSL =
  \\@group(0) @binding(0) var<storage, read_write> out: array<i32>;
  \\@compute @workgroup_size(64)
  \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  \\  let i = gid.x;
  \\  if (i >= arrayLength(&out)) { return; }
  \\  out[i] = i32(i);
  \\}
  \\
;

// Dyad kernel template. dtype is "i32" or "f32". Single arena binding
// with element-offset uniforms; both types are 4 bytes so element
// offset = byte_offset / 4.
fn dyadWgsl(comptime dtype: []const u8, comptime op_expr: []const u8) []const u8 {
  return
    "struct Params { x_off: u32, y_off: u32, out_off: u32, n: u32 };\n" ++
    "@group(0) @binding(0) var<storage, read_write> arena: array<" ++ dtype ++ ">;\n" ++
    "@group(0) @binding(1) var<uniform> p: Params;\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n" ++
    "  let i = gid.x;\n" ++
    "  if (i >= p.n) { return; }\n" ++
    "  let a = arena[p.x_off + i];\n" ++
    "  let b = arena[p.y_off + i];\n" ++
    "  arena[p.out_off + i] = " ++ op_expr ++ ";\n" ++
    "}\n";
}

// i32 dyad kernels (div: truncating, 0/0 -> 0 to avoid UB).
const ADD_I32_WGSL = dyadWgsl("i32", "a + b");
const SUB_I32_WGSL = dyadWgsl("i32", "a - b");
const MUL_I32_WGSL = dyadWgsl("i32", "a * b");
const DIV_I32_WGSL = dyadWgsl("i32", "select(a / b, 0, b == 0)");
const MIN_I32_WGSL = dyadWgsl("i32", "min(a, b)");
const MAX_I32_WGSL = dyadWgsl("i32", "max(a, b)");

// f32 dyad kernels (includes div since % is float division in K).
const ADD_F32_WGSL = dyadWgsl("f32", "a + b");
const SUB_F32_WGSL = dyadWgsl("f32", "a - b");
const MUL_F32_WGSL = dyadWgsl("f32", "a * b");
const DIV_F32_WGSL = dyadWgsl("f32", "a / b");
const MIN_F32_WGSL = dyadWgsl("f32", "min(a, b)");
const MAX_F32_WGSL = dyadWgsl("f32", "max(a, b)");

// Monad kernel template.
fn monadWgsl(comptime dtype: []const u8, comptime op_expr: []const u8) []const u8 {
  return
    "struct Params { x_off: u32, out_off: u32, n: u32, _pad: u32 };\n" ++
    "@group(0) @binding(0) var<storage, read_write> arena: array<" ++ dtype ++ ">;\n" ++
    "@group(0) @binding(1) var<uniform> p: Params;\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n" ++
    "  let i = gid.x;\n" ++
    "  if (i >= p.n) { return; }\n" ++
    "  let x = arena[p.x_off + i];\n" ++
    "  arena[p.out_off + i] = " ++ op_expr ++ ";\n" ++
    "}\n";
}

const NEG_I32_WGSL = monadWgsl("i32", "-x");
const ABS_I32_WGSL = monadWgsl("i32", "abs(x)");
const NEG_F32_WGSL = monadWgsl("f32", "-x");
const ABS_F32_WGSL = monadWgsl("f32", "abs(x)");

// Reduce kernel template. Single workgroup of 256 threads tree-reduces
// the input across grid-stride strides. Works for any n; for very
// large n the grid-stride loop in each thread does the heavy lifting.
// Output is one element of `dtype` written at p.out_off.
const REDUCE_WG: u32 = 256;
// `combine` is a binary expression in identifiers `a` and `v`,
// e.g. "a + v" or "min(a, v)".
fn reduceWgsl(comptime dtype: []const u8, comptime init_lit: []const u8, comptime combine: []const u8) []const u8 {
  return
    "struct Params { in_off: u32, out_off: u32, n: u32, _pad: u32 };\n" ++
    "@group(0) @binding(0) var<storage, read_write> arena: array<" ++ dtype ++ ">;\n" ++
    "@group(0) @binding(1) var<uniform> p: Params;\n" ++
    "var<workgroup> wg: array<" ++ dtype ++ ", 256>;\n" ++
    "@compute @workgroup_size(256)\n" ++
    "fn main(@builtin(local_invocation_id) lid: vec3<u32>) {\n" ++
    "  let tid = lid.x;\n" ++
    "  var a: " ++ dtype ++ " = " ++ init_lit ++ ";\n" ++
    "  var i: u32 = tid;\n" ++
    "  while (i < p.n) { let v = arena[p.in_off + i]; a = " ++ combine ++ "; i += 256u; }\n" ++
    "  wg[tid] = a;\n" ++
    "  workgroupBarrier();\n" ++
    "  var stride: u32 = 128u;\n" ++
    "  while (stride > 0u) {\n" ++
    "    if (tid < stride) {\n" ++
    "      let lhs = wg[tid]; let v = wg[tid + stride]; let a = lhs; wg[tid] = " ++ combine ++ ";\n" ++
    "    }\n" ++
    "    workgroupBarrier();\n" ++
    "    stride = stride >> 1u;\n" ++
    "  }\n" ++
    "  if (tid == 0u) { arena[p.out_off] = wg[0]; }\n" ++
    "}\n";
}

// `combine` is a binary expression in identifiers `a` and `v`.
const REDUCE_ADD_I32_WGSL = reduceWgsl("i32", "0",                 "a + v");
const REDUCE_MUL_I32_WGSL = reduceWgsl("i32", "1",                 "a * v");
const REDUCE_MIN_I32_WGSL = reduceWgsl("i32", "i32(0x7fffffffu)",  "min(a, v)");
const REDUCE_MAX_I32_WGSL = reduceWgsl("i32", "i32(0x80000000u)",  "max(a, v)");

const REDUCE_ADD_F32_WGSL = reduceWgsl("f32", "0.0",           "a + v");
const REDUCE_MUL_F32_WGSL = reduceWgsl("f32", "1.0",           "a * v");
const REDUCE_MIN_F32_WGSL = reduceWgsl("f32", "3.4028235e38",  "min(a, v)");
const REDUCE_MAX_F32_WGSL = reduceWgsl("f32", "-3.4028235e38", "max(a, v)");

// Hillis-Steele prefix scan step kernel.
// One pass: out[i] = in[i] OP in[i - stride]  (or in[i] when i < stride).
// Run ceil(log2(n)) times, alternating between two arena regions, to get
// inclusive prefix scan.
fn scanStepWgsl(comptime dtype: []const u8, comptime op_expr: []const u8) []const u8 {
  return
    "struct Params { in_off: u32, out_off: u32, n: u32, stride: u32 };\n" ++
    "@group(0) @binding(0) var<storage, read_write> arena: array<" ++ dtype ++ ">;\n" ++
    "@group(0) @binding(1) var<uniform> p: Params;\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n" ++
    "  let i = gid.x;\n" ++
    "  if (i >= p.n) { return; }\n" ++
    "  let a = arena[p.in_off + i];\n" ++
    "  if (i >= p.stride) {\n" ++
    "    let b = arena[p.in_off + i - p.stride];\n" ++
    "    arena[p.out_off + i] = " ++ op_expr ++ ";\n" ++
    "  } else {\n" ++
    "    arena[p.out_off + i] = a;\n" ++
    "  }\n" ++
    "}\n";
}

const SCAN_ADD_I32_WGSL = scanStepWgsl("i32", "a + b");
const SCAN_MUL_I32_WGSL = scanStepWgsl("i32", "a * b");
const SCAN_ADD_F32_WGSL = scanStepWgsl("f32", "a + b");
const SCAN_MUL_F32_WGSL = scanStepWgsl("f32", "a * b");

extern fn dniCreate() ?*anyopaque;
extern fn dniDestroy(dni: ?*anyopaque) void;
extern fn dniGetWgpuInstance(dni: ?*anyopaque) ?wgpu.Instance;
extern fn dnGetProcs() ?*anyopaque;
extern fn dawnProcSetProcs(procs: ?*anyopaque) void;

// zgpu only exposes getMappedRange (read-write); MAP_READ buffers need
// getConstMappedRange instead.
extern fn wgpuBufferGetConstMappedRange(buffer: wgpu.Buffer, offset: usize, size: usize) ?*const anyopaque;

pub const WgpuBackend = struct {
  ctx: gpu.GpuCtx,

  alloc:           Alloc,
  native_instance: ?*anyopaque,
  instance:        wgpu.Instance,
  adapter:         wgpu.Adapter,
  device:          wgpu.Device,
  queue:           wgpu.Queue,

  arena_buf:   wgpu.Buffer,
  arena_used:  u32 = 0,
  staging_buf: wgpu.Buffer,
  uniform_buf: wgpu.Buffer, // 16-byte Params, written before each dispatch

  iota_pipeline:  ?wgpu.ComputePipeline = null,
  iota_layout:    ?wgpu.BindGroupLayout = null,
  // One pipeline per (op, dtype), lazily compiled.
  dyad_i32_pipelines:  [@typeInfo(gpu.DyadOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.DyadOp).@"enum".fields.len,
  dyad_f32_pipelines:  [@typeInfo(gpu.DyadOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.DyadOp).@"enum".fields.len,
  monad_i32_pipelines:  [@typeInfo(gpu.MonadOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.MonadOp).@"enum".fields.len,
  monad_f32_pipelines:  [@typeInfo(gpu.MonadOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.MonadOp).@"enum".fields.len,
  reduce_i32_pipelines: [@typeInfo(gpu.ReduceOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.ReduceOp).@"enum".fields.len,
  reduce_f32_pipelines: [@typeInfo(gpu.ReduceOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.ReduceOp).@"enum".fields.len,
  scan_i32_pipelines:   [@typeInfo(gpu.ScanOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.ScanOp).@"enum".fields.len,
  scan_f32_pipelines:   [@typeInfo(gpu.ScanOp).@"enum".fields.len]?wgpu.ComputePipeline = .{null} ** @typeInfo(gpu.ScanOp).@"enum".fields.len,

  pub const vtable: gpu.VTable = .{
    .free        = freeImpl,
    .alloc_range = allocImpl,
    .read        = readImpl,
    .iota_i32    = iotaImpl,
    .dyad_i32    = dyadI32Impl,
    .dyad_f32    = dyadF32Impl,
    .monad_i32   = monadI32Impl,
    .monad_f32   = monadF32Impl,
    .reduce_i32  = reduceI32Impl,
    .reduce_f32  = reduceF32Impl,
    .scan_i32    = scanI32Impl,
    .scan_f32    = scanF32Impl,
  };

  pub fn create(alloc: Alloc) !*WgpuBackend {
    const self = try alloc.create(WgpuBackend);
    errdefer alloc.destroy(self);

    dawnProcSetProcs(dnGetProcs());
    const ni = dniCreate();
    errdefer dniDestroy(ni);

    const instance = dniGetWgpuInstance(ni) orelse return error.NoInstance;
    const adapter = try requestAdapter(instance);
    errdefer adapter.release();
    const device = try requestDevice(adapter);
    errdefer device.release();
    device.setUncapturedErrorCallback(struct {
      fn cb(et: wgpu.ErrorType, msg: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
        std.debug.print("[wgpu err {s}] {s}\n", .{ @tagName(et), msg orelse "(no msg)" });
      }
    }.cb, null);
    const queue = device.getQueue();

    const arena_buf = device.createBuffer(.{
      .label = "ink-arena",
      .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
      .size  = ARENA_BYTES,
    });
    errdefer arena_buf.release();

    const staging_buf = device.createBuffer(.{
      .label = "ink-staging",
      .usage = .{ .map_read = true, .copy_dst = true },
      .size  = STAGING_BYTES,
    });
    errdefer staging_buf.release();

    const uniform_buf = device.createBuffer(.{
      .label = "ink-uniforms",
      .usage = .{ .uniform = true, .copy_dst = true },
      .size  = 256, // 256 to satisfy min uniform buffer offset alignment
    });
    errdefer uniform_buf.release();

    self.* = .{
      .ctx = .{ .alloc = alloc, .vtable = &vtable },
      .alloc = alloc,
      .native_instance = ni,
      .instance = instance,
      .adapter = adapter,
      .device = device,
      .queue = queue,
      .arena_buf = arena_buf,
      .staging_buf = staging_buf,
      .uniform_buf = uniform_buf,
    };
    return self;
  }

  pub fn destroy(self: *WgpuBackend) void {
    if (self.iota_pipeline) |p| p.release();
    if (self.iota_layout) |l| l.release();
    for (self.dyad_i32_pipelines)  |p| if (p) |pp| pp.release();
    for (self.dyad_f32_pipelines)  |p| if (p) |pp| pp.release();
    for (self.monad_i32_pipelines)  |p| if (p) |pp| pp.release();
    for (self.monad_f32_pipelines)  |p| if (p) |pp| pp.release();
    for (self.reduce_i32_pipelines) |p| if (p) |pp| pp.release();
    for (self.reduce_f32_pipelines) |p| if (p) |pp| pp.release();
    for (self.scan_i32_pipelines)   |p| if (p) |pp| pp.release();
    for (self.scan_f32_pipelines)   |p| if (p) |pp| pp.release();
    self.uniform_buf.release();
    self.staging_buf.release();
    self.arena_buf.release();
    self.queue.release();
    self.device.release();
    self.adapter.release();
    dniDestroy(self.native_instance);
    self.alloc.destroy(self);
  }

  // -- arena -----------------------------------------------------------------

  fn allocImpl(ctx: *gpu.GpuCtx, byte_len: u32) anyerror!gpu.GpuRange {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const aligned = std.mem.alignForward(u32, byte_len, MIN_OFFSET_ALIGN);
    if (self.arena_used + aligned > ARENA_BYTES) return error.ArenaFull;
    const offset = self.arena_used;
    self.arena_used += aligned;
    return .{ .buf = ARENA_BUF, .offset = offset };
  }

  fn freeImpl(_: *gpu.GpuCtx, _: gpu.GpuRange, _: u32) void {
    // Bump allocator; slabs reclaimed on backend destroy.
  }

  // -- readback --------------------------------------------------------------

  fn readImpl(ctx: *gpu.GpuCtx, range: gpu.GpuRange, dst: []u8) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    if (dst.len > STAGING_BYTES) return error.ReadTooLarge;
    const enc = self.device.createCommandEncoder(null);
    enc.copyBufferToBuffer(self.arena_buf, range.offset, self.staging_buf, 0, dst.len);
    const cmd = enc.finish(null);
    self.queue.submit(&.{cmd});
    cmd.release();
    enc.release();

    const Status = struct { done: bool = false, status: wgpu.BufferMapAsyncStatus = .unknown };
    var status = Status{};
    self.staging_buf.mapAsync(.{ .read = true }, 0, dst.len, struct {
      fn cb(s: wgpu.BufferMapAsyncStatus, ud: ?*anyopaque) callconv(.c) void {
        const sp: *Status = @ptrCast(@alignCast(ud));
        sp.status = s; sp.done = true;
      }
    }.cb, &status);

    while (!status.done) self.device.tick();
    if (status.status != .success) return error.MapFailed;

    const mapped = self.staging_buf.getConstMappedRange(u8, 0, dst.len) orelse return error.MapNull;
    @memcpy(dst, mapped);
    self.staging_buf.unmap();
  }

  // -- pipeline factory ------------------------------------------------------

  fn buildPipeline(self: *WgpuBackend, label: [*:0]const u8, wgsl: []const u8) !wgpu.ComputePipeline {
    const buf = try self.alloc.allocSentinel(u8, wgsl.len, 0);
    defer self.alloc.free(buf);
    @memcpy(buf, wgsl);
    const wgsl_desc = wgpu.ShaderModuleWGSLDescriptor{
      .chain = .{ .next = null, .struct_type = .shader_module_wgsl_descriptor },
      .code = buf.ptr,
    };
    const module = self.device.createShaderModule(.{
      .next_in_chain = @ptrCast(&wgsl_desc), .label = label,
    });
    defer module.release();
    return self.device.createComputePipeline(.{
      .label = label, .layout = null,
      .compute = .{ .module = module, .entry_point = "main" },
    });
  }

  fn ensureDyadI32Pipeline(self: *WgpuBackend, op: gpu.DyadOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.dyad_i32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) {
      .add => ADD_I32_WGSL, .sub => SUB_I32_WGSL, .mul => MUL_I32_WGSL,
      .div => DIV_I32_WGSL, .min => MIN_I32_WGSL, .max => MAX_I32_WGSL,
    };
    const p = try self.buildPipeline("dyad-i32", wgsl);
    self.dyad_i32_pipelines[slot] = p;
    return p;
  }

  fn ensureDyadF32Pipeline(self: *WgpuBackend, op: gpu.DyadOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.dyad_f32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) {
      .add => ADD_F32_WGSL, .sub => SUB_F32_WGSL, .mul => MUL_F32_WGSL,
      .div => DIV_F32_WGSL, .min => MIN_F32_WGSL, .max => MAX_F32_WGSL,
    };
    const p = try self.buildPipeline("dyad-f32", wgsl);
    self.dyad_f32_pipelines[slot] = p;
    return p;
  }

  fn ensureMonadI32Pipeline(self: *WgpuBackend, op: gpu.MonadOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.monad_i32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) { .neg => NEG_I32_WGSL, .abs => ABS_I32_WGSL };
    const p = try self.buildPipeline("monad-i32", wgsl);
    self.monad_i32_pipelines[slot] = p;
    return p;
  }

  fn ensureMonadF32Pipeline(self: *WgpuBackend, op: gpu.MonadOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.monad_f32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) { .neg => NEG_F32_WGSL, .abs => ABS_F32_WGSL };
    const p = try self.buildPipeline("monad-f32", wgsl);
    self.monad_f32_pipelines[slot] = p;
    return p;
  }

  fn ensureReduceI32Pipeline(self: *WgpuBackend, op: gpu.ReduceOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.reduce_i32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) {
      .add => REDUCE_ADD_I32_WGSL, .mul => REDUCE_MUL_I32_WGSL,
      .min => REDUCE_MIN_I32_WGSL, .max => REDUCE_MAX_I32_WGSL,
    };
    const p = try self.buildPipeline("reduce-i32", wgsl);
    self.reduce_i32_pipelines[slot] = p;
    return p;
  }

  fn ensureReduceF32Pipeline(self: *WgpuBackend, op: gpu.ReduceOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.reduce_f32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) {
      .add => REDUCE_ADD_F32_WGSL, .mul => REDUCE_MUL_F32_WGSL,
      .min => REDUCE_MIN_F32_WGSL, .max => REDUCE_MAX_F32_WGSL,
    };
    const p = try self.buildPipeline("reduce-f32", wgsl);
    self.reduce_f32_pipelines[slot] = p;
    return p;
  }

  fn ensureScanI32Pipeline(self: *WgpuBackend, op: gpu.ScanOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.scan_i32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) { .add => SCAN_ADD_I32_WGSL, .mul => SCAN_MUL_I32_WGSL };
    const p = try self.buildPipeline("scan-i32", wgsl);
    self.scan_i32_pipelines[slot] = p;
    return p;
  }

  fn ensureScanF32Pipeline(self: *WgpuBackend, op: gpu.ScanOp) !wgpu.ComputePipeline {
    const slot = @intFromEnum(op);
    if (self.scan_f32_pipelines[slot]) |p| return p;
    const wgsl = switch (op) { .add => SCAN_ADD_F32_WGSL, .mul => SCAN_MUL_F32_WGSL };
    const p = try self.buildPipeline("scan-f32", wgsl);
    self.scan_f32_pipelines[slot] = p;
    return p;
  }

  // -- shared dispatch bodies ------------------------------------------------

  fn submitDyad(self: *WgpuBackend, pipeline: wgpu.ComputePipeline,
                out: gpu.GpuRange, x: gpu.GpuRange, y: gpu.GpuRange, n: u32) void {
    // Both i32 and f32 are 4 bytes, so element offset = byte_offset / 4.
    const params = [4]u32{ x.offset / 4, y.offset / 4, out.offset / 4, n };
    self.queue.writeBuffer(self.uniform_buf, 0, u32, params[0..]);
    const auto_layout = pipeline.getBindGroupLayout(0);
    defer auto_layout.release();
    const entries = [_]wgpu.BindGroupEntry{
      .{ .binding = 0, .buffer = self.arena_buf, .offset = 0, .size = ARENA_BYTES },
      .{ .binding = 1, .buffer = self.uniform_buf, .offset = 0, .size = @sizeOf(@TypeOf(params)) },
    };
    const bg = self.device.createBindGroup(.{
      .layout = auto_layout, .entry_count = entries.len, .entries = &entries,
    });
    defer bg.release();
    const enc = self.device.createCommandEncoder(null);
    const pass = enc.beginComputePass(null);
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, &.{});
    pass.dispatchWorkgroups((n + 63) / 64, 1, 1);
    pass.end(); pass.release();
    const cmd = enc.finish(null);
    self.queue.submit(&.{cmd});
    cmd.release(); enc.release();
  }

  fn submitMonad(self: *WgpuBackend, pipeline: wgpu.ComputePipeline,
                 out: gpu.GpuRange, x: gpu.GpuRange, n: u32) void {
    const params = [4]u32{ x.offset / 4, out.offset / 4, n, 0 };
    self.queue.writeBuffer(self.uniform_buf, 0, u32, params[0..]);
    const auto_layout = pipeline.getBindGroupLayout(0);
    defer auto_layout.release();
    const entries = [_]wgpu.BindGroupEntry{
      .{ .binding = 0, .buffer = self.arena_buf, .offset = 0, .size = ARENA_BYTES },
      .{ .binding = 1, .buffer = self.uniform_buf, .offset = 0, .size = @sizeOf(@TypeOf(params)) },
    };
    const bg = self.device.createBindGroup(.{
      .layout = auto_layout, .entry_count = entries.len, .entries = &entries,
    });
    defer bg.release();
    const enc = self.device.createCommandEncoder(null);
    const pass = enc.beginComputePass(null);
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, &.{});
    pass.dispatchWorkgroups((n + 63) / 64, 1, 1);
    pass.end(); pass.release();
    const cmd = enc.finish(null);
    self.queue.submit(&.{cmd});
    cmd.release(); enc.release();
  }

  // Reduce: single workgroup of 256 threads.
  fn submitReduce(self: *WgpuBackend, pipeline: wgpu.ComputePipeline,
                  out: gpu.GpuRange, x: gpu.GpuRange, n: u32) void {
    const params = [4]u32{ x.offset / 4, out.offset / 4, n, 0 };
    self.queue.writeBuffer(self.uniform_buf, 0, u32, params[0..]);
    const auto_layout = pipeline.getBindGroupLayout(0);
    defer auto_layout.release();
    const entries = [_]wgpu.BindGroupEntry{
      .{ .binding = 0, .buffer = self.arena_buf, .offset = 0, .size = ARENA_BYTES },
      .{ .binding = 1, .buffer = self.uniform_buf, .offset = 0, .size = @sizeOf(@TypeOf(params)) },
    };
    const bg = self.device.createBindGroup(.{
      .layout = auto_layout, .entry_count = entries.len, .entries = &entries,
    });
    defer bg.release();
    const enc = self.device.createCommandEncoder(null);
    const pass = enc.beginComputePass(null);
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, &.{});
    pass.dispatchWorkgroups(1, 1, 1); // single workgroup; threads do grid-stride loop
    pass.end(); pass.release();
    const cmd = enc.finish(null);
    self.queue.submit(&.{cmd});
    cmd.release(); enc.release();
  }

  fn submitScanStep(self: *WgpuBackend, pipeline: wgpu.ComputePipeline,
                    in: gpu.GpuRange, out: gpu.GpuRange, n: u32, stride: u32) void {
    const params = [4]u32{ in.offset / 4, out.offset / 4, n, stride };
    self.queue.writeBuffer(self.uniform_buf, 0, u32, params[0..]);
    const auto_layout = pipeline.getBindGroupLayout(0);
    defer auto_layout.release();
    const entries = [_]wgpu.BindGroupEntry{
      .{ .binding = 0, .buffer = self.arena_buf, .offset = 0, .size = ARENA_BYTES },
      .{ .binding = 1, .buffer = self.uniform_buf, .offset = 0, .size = @sizeOf(@TypeOf(params)) },
    };
    const bg = self.device.createBindGroup(.{
      .layout = auto_layout, .entry_count = entries.len, .entries = &entries,
    });
    defer bg.release();
    const enc = self.device.createCommandEncoder(null);
    const pass = enc.beginComputePass(null);
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, &.{});
    pass.dispatchWorkgroups((n + 63) / 64, 1, 1);
    pass.end(); pass.release();
    const cmd = enc.finish(null);
    self.queue.submit(&.{cmd});
    cmd.release(); enc.release();
  }

  // Hillis-Steele inclusive prefix scan. Allocates a scratch region, runs
  // ceil(log2(n)) step-kernel dispatches, copies to `out` if the last pass
  // landed in scratch. `elem_bytes` is 4 for both i32 and f32.
  fn executeScan(self: *WgpuBackend, pipeline: wgpu.ComputePipeline,
                 out: gpu.GpuRange, x: gpu.GpuRange, n: u32, elem_bytes: u32) !void {
    if (n == 0) return;
    if (n == 1) {
      const enc = self.device.createCommandEncoder(null);
      enc.copyBufferToBuffer(self.arena_buf, x.offset, self.arena_buf, out.offset, elem_bytes);
      const cmd = enc.finish(null);
      self.queue.submit(&.{cmd});
      cmd.release(); enc.release();
      return;
    }
    const scratch = try allocImpl(&self.ctx, n * elem_bytes);

    var cur_in  = x;
    var cur_out = out;
    var stride: u32 = 1;
    while (stride < n) : (stride <<= 1) {
      self.submitScanStep(pipeline, cur_in, cur_out, n, stride);
      const prev_out = cur_out;
      cur_in  = prev_out;
      cur_out = if (prev_out.offset == out.offset) scratch else out;
    }
    // If the final result is in scratch, copy it to out.
    if (cur_in.offset != out.offset) {
      const enc = self.device.createCommandEncoder(null);
      enc.copyBufferToBuffer(self.arena_buf, cur_in.offset, self.arena_buf, out.offset, n * elem_bytes);
      const cmd = enc.finish(null);
      self.queue.submit(&.{cmd});
      cmd.release(); enc.release();
    }
  }

  // -- vtable implementations ------------------------------------------------

  fn dyadI32Impl(ctx: *gpu.GpuCtx, op: gpu.DyadOp, out: gpu.GpuRange, x: gpu.GpuRange, y: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureDyadI32Pipeline(op);
    self.submitDyad(p, out, x, y, n);
  }

  fn dyadF32Impl(ctx: *gpu.GpuCtx, op: gpu.DyadOp, out: gpu.GpuRange, x: gpu.GpuRange, y: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureDyadF32Pipeline(op);
    self.submitDyad(p, out, x, y, n);
  }

  fn monadI32Impl(ctx: *gpu.GpuCtx, op: gpu.MonadOp, out: gpu.GpuRange, x: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureMonadI32Pipeline(op);
    self.submitMonad(p, out, x, n);
  }

  fn monadF32Impl(ctx: *gpu.GpuCtx, op: gpu.MonadOp, out: gpu.GpuRange, x: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureMonadF32Pipeline(op);
    self.submitMonad(p, out, x, n);
  }

  fn reduceI32Impl(ctx: *gpu.GpuCtx, op: gpu.ReduceOp, out: gpu.GpuRange, x: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureReduceI32Pipeline(op);
    self.submitReduce(p, out, x, n);
  }

  fn reduceF32Impl(ctx: *gpu.GpuCtx, op: gpu.ReduceOp, out: gpu.GpuRange, x: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureReduceF32Pipeline(op);
    self.submitReduce(p, out, x, n);
  }

  fn scanI32Impl(ctx: *gpu.GpuCtx, op: gpu.ScanOp, out: gpu.GpuRange, x: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureScanI32Pipeline(op);
    try self.executeScan(p, out, x, n, @sizeOf(i32));
  }

  fn scanF32Impl(ctx: *gpu.GpuCtx, op: gpu.ScanOp, out: gpu.GpuRange, x: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    const p = try self.ensureScanF32Pipeline(op);
    try self.executeScan(p, out, x, n, @sizeOf(f32));
  }

  // -- iota kernel -----------------------------------------------------------

  fn ensureIotaPipeline(self: *WgpuBackend) !void {
    if (self.iota_pipeline != null) return;
    const wgsl_desc = wgpu.ShaderModuleWGSLDescriptor{
      .chain = .{ .next = null, .struct_type = .shader_module_wgsl_descriptor },
      .code = IOTA_WGSL,
    };
    const module = self.device.createShaderModule(.{
      .next_in_chain = @ptrCast(&wgsl_desc), .label = "iota",
    });
    defer module.release();
    const layout_entries = [_]wgpu.BindGroupLayoutEntry{.{
      .binding = 0, .visibility = .{ .compute = true },
      .buffer = .{ .binding_type = .storage, .has_dynamic_offset = .false, .min_binding_size = 0 },
    }};
    const bgl = self.device.createBindGroupLayout(.{
      .entry_count = layout_entries.len, .entries = &layout_entries,
    });
    const pipeline = self.device.createComputePipeline(.{
      .label = "iota-pipeline", .layout = null,
      .compute = .{ .module = module, .entry_point = "main" },
    });
    self.iota_layout = bgl;
    self.iota_pipeline = pipeline;
  }

  fn iotaImpl(ctx: *gpu.GpuCtx, range: gpu.GpuRange, n: u32) anyerror!void {
    const self: *WgpuBackend = @fieldParentPtr("ctx", ctx);
    try self.ensureIotaPipeline();
    const pipeline = self.iota_pipeline.?;
    const byte_size = n * @sizeOf(i32);
    const auto_layout = pipeline.getBindGroupLayout(0);
    defer auto_layout.release();
    const entries = [_]wgpu.BindGroupEntry{
      .{ .binding = 0, .buffer = self.arena_buf, .offset = range.offset, .size = byte_size },
    };
    const bg = self.device.createBindGroup(.{
      .layout = auto_layout, .entry_count = entries.len, .entries = &entries,
    });
    defer bg.release();
    const enc = self.device.createCommandEncoder(null);
    const pass = enc.beginComputePass(null);
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bg, &.{});
    pass.dispatchWorkgroups((n + 63) / 64, 1, 1);
    pass.end(); pass.release();
    const cmd = enc.finish(null);
    self.queue.submit(&.{cmd});
    cmd.release(); enc.release();
  }
};

// -- adapter / device sync request -------------------------------------------

fn requestAdapter(instance: wgpu.Instance) !wgpu.Adapter {
  const Resp = struct { status: wgpu.RequestAdapterStatus = .unknown, adapter: wgpu.Adapter = undefined, done: bool = false };
  var resp = Resp{};
  instance.requestAdapter(.{ .power_preference = .high_performance }, struct {
    fn run(status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, _: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
      const r: *Resp = @ptrCast(@alignCast(ud));
      r.status = status; r.adapter = adapter; r.done = true;
    }
  }.run, &resp);
  // Native: callback fires synchronously inside requestAdapter.
  if (resp.status != .success) return error.NoAdapter;
  return resp.adapter;
}

fn requestDevice(adapter: wgpu.Adapter) !wgpu.Device {
  const Resp = struct { status: wgpu.RequestDeviceStatus = .unknown, device: wgpu.Device = undefined, done: bool = false };
  var resp = Resp{};
  adapter.requestDevice(.{ .label = "ink" }, struct {
    fn run(status: wgpu.RequestDeviceStatus, device: wgpu.Device, _: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
      const r: *Resp = @ptrCast(@alignCast(ud));
      r.status = status; r.device = device; r.done = true;
    }
  }.run, &resp);
  if (resp.status != .success) return error.NoDevice;
  return resp.device;
}

// -- tests -------------------------------------------------------------------

test "iota round-trip" {
  const alloc = std.testing.allocator;
  const backend = try WgpuBackend.create(alloc);
  defer backend.destroy();

  const N: u32 = 1024;
  const range = try backend.ctx.allocRange(N * @sizeOf(i32));
  try backend.ctx.iotaI32(range, N);

  var out: [N]i32 = undefined;
  try backend.ctx.read(range, std.mem.sliceAsBytes(out[0..]));
  for (out, 0..) |v, i| try std.testing.expectEqual(@as(i32, @intCast(i)), v);
}

test "i32 dyad: iota + iota = 2*iota" {
  const alloc = std.testing.allocator;
  const backend = try WgpuBackend.create(alloc);
  defer backend.destroy();

  const N: u32 = 4096;
  const a   = try backend.ctx.allocRange(N * @sizeOf(i32));
  const b   = try backend.ctx.allocRange(N * @sizeOf(i32));
  const out = try backend.ctx.allocRange(N * @sizeOf(i32));
  try backend.ctx.iotaI32(a, N);
  try backend.ctx.iotaI32(b, N);
  try backend.ctx.dyadI32(.add, out, a, b, N);

  var got: [N]i32 = undefined;
  try backend.ctx.read(out, std.mem.sliceAsBytes(got[0..]));
  for (got, 0..) |v, i| try std.testing.expectEqual(@as(i32, @intCast(i * 2)), v);
}

test "f32 dyad: 3.0 * 3.0 = 9.0" {
  const alloc = std.testing.allocator;
  const backend = try WgpuBackend.create(alloc);
  defer backend.destroy();

  const N: u32 = 1024;
  const a   = try backend.ctx.allocRange(N * @sizeOf(f32));
  const b   = try backend.ctx.allocRange(N * @sizeOf(f32));
  const out = try backend.ctx.allocRange(N * @sizeOf(f32));

  var input: [N]f32 = undefined;
  @memset(&input, 3.0);
  backend.queue.writeBuffer(backend.arena_buf, a.offset, f32, input[0..]);
  backend.queue.writeBuffer(backend.arena_buf, b.offset, f32, input[0..]);

  try backend.ctx.dyadF32(.mul, out, a, b, N);

  var got: [N]f32 = undefined;
  try backend.ctx.read(out, std.mem.sliceAsBytes(got[0..]));
  for (got) |v| try std.testing.expectApproxEqAbs(@as(f32, 9.0), v, 1e-5);
}

test "i32 reduce: sum of iota" {
  const alloc = std.testing.allocator;
  const backend = try WgpuBackend.create(alloc);
  defer backend.destroy();

  const N: u32 = 4096;
  const x   = try backend.ctx.allocRange(N * @sizeOf(i32));
  const out = try backend.ctx.allocRange(@sizeOf(i32));
  try backend.ctx.iotaI32(x, N);
  try backend.ctx.reduceI32(.add, out, x, N);

  var got: [1]i32 = undefined;
  try backend.ctx.read(out, std.mem.sliceAsBytes(got[0..]));
  // sum 0..N-1 = N*(N-1)/2 = 4096*4095/2 = 8,386,560
  try std.testing.expectEqual(@as(i32, @intCast((@as(u64, N) * (N - 1)) / 2)), got[0]);
}

test "i32 reduce: max of iota" {
  const alloc = std.testing.allocator;
  const backend = try WgpuBackend.create(alloc);
  defer backend.destroy();

  const N: u32 = 1024;
  const x   = try backend.ctx.allocRange(N * @sizeOf(i32));
  const out = try backend.ctx.allocRange(@sizeOf(i32));
  try backend.ctx.iotaI32(x, N);
  try backend.ctx.reduceI32(.max, out, x, N);

  var got: [1]i32 = undefined;
  try backend.ctx.read(out, std.mem.sliceAsBytes(got[0..]));
  try std.testing.expectEqual(@as(i32, @intCast(N - 1)), got[0]);
}

test "i32 scan: prefix sum of iota" {
  const alloc = std.testing.allocator;
  const backend = try WgpuBackend.create(alloc);
  defer backend.destroy();

  const N: u32 = 4096;
  const x   = try backend.ctx.allocRange(N * @sizeOf(i32));
  const out = try backend.ctx.allocRange(N * @sizeOf(i32));
  try backend.ctx.iotaI32(x, N);
  try backend.ctx.scanI32(.add, out, x, N);

  var got: [N]i32 = undefined;
  try backend.ctx.read(out, std.mem.sliceAsBytes(got[0..]));
  // out[i] = 0+1+...+i = i*(i+1)/2
  for (got, 0..) |v, i| {
    const expected: i32 = @intCast(i * (i + 1) / 2);
    try std.testing.expectEqual(expected, v);
  }
}

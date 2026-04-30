// Storage-side GPU types. value.zig imports this for the type surface
// it needs to carry a back-reference in Rc headers. The actual wgpu
// device, arena, pipelines, and kernels live in gpu_wgpu.zig.
//
// GpuCtx here is an interface (alloc + vtable). A concrete backend
// (e.g. gpu_wgpu.WgpuBackend) embeds a GpuCtx field and fills in the
// vtable. Verbs and value.zig only see this surface, so the real wgpu
// dependency stays out of the test build.

const std = @import("std");

pub const Loc = enum(u32) { cpu = 0, gpu = 1 };

pub const BufferHandle = enum(u32) { invalid = 0, _ };

pub const GpuRange = extern struct {
  buf:    BufferHandle = .invalid,
  offset: u32 = 0,
};

pub const DyadOp = enum(u8) { add, sub, mul, div, min, max };
pub const MonadOp = enum(u8) { neg, abs };
pub const ReduceOp = enum(u8) { add, mul, min, max };
pub const ScanOp  = enum(u8) { add, mul };

pub const VTable = struct {
  free:        *const fn (*GpuCtx, GpuRange, u32) void,
  alloc_range: *const fn (*GpuCtx, u32) anyerror!GpuRange,
  read:        *const fn (*GpuCtx, GpuRange, []u8) anyerror!void,
  iota_i32:    *const fn (*GpuCtx, GpuRange, u32) anyerror!void,
  dyad_i32:    *const fn (*GpuCtx, DyadOp, GpuRange, GpuRange, GpuRange, u32) anyerror!void,
  dyad_f32:    *const fn (*GpuCtx, DyadOp, GpuRange, GpuRange, GpuRange, u32) anyerror!void,
  monad_i32:   *const fn (*GpuCtx, MonadOp, GpuRange, GpuRange, u32) anyerror!void,
  monad_f32:   *const fn (*GpuCtx, MonadOp, GpuRange, GpuRange, u32) anyerror!void,
  reduce_i32:  *const fn (*GpuCtx, ReduceOp, GpuRange, GpuRange, u32) anyerror!void,
  reduce_f32:  *const fn (*GpuCtx, ReduceOp, GpuRange, GpuRange, u32) anyerror!void,
  scan_i32:    *const fn (*GpuCtx, ScanOp,   GpuRange, GpuRange, u32) anyerror!void,
  scan_f32:    *const fn (*GpuCtx, ScanOp,   GpuRange, GpuRange, u32) anyerror!void,
};

pub const GpuCtx = struct {
  alloc:  std.mem.Allocator,
  vtable: *const VTable,

  pub fn free(self: *GpuCtx, range: GpuRange, byte_len: u32) void {
    self.vtable.free(self, range, byte_len);
  }
  pub fn allocRange(self: *GpuCtx, byte_len: u32) !GpuRange {
    return self.vtable.alloc_range(self, byte_len);
  }
  pub fn read(self: *GpuCtx, range: GpuRange, dst: []u8) !void {
    return self.vtable.read(self, range, dst);
  }
  pub fn iotaI32(self: *GpuCtx, range: GpuRange, n: u32) !void {
    return self.vtable.iota_i32(self, range, n);
  }
  pub fn dyadI32(self: *GpuCtx, op: DyadOp, out: GpuRange, x: GpuRange, y: GpuRange, n: u32) !void {
    return self.vtable.dyad_i32(self, op, out, x, y, n);
  }
  pub fn dyadF32(self: *GpuCtx, op: DyadOp, out: GpuRange, x: GpuRange, y: GpuRange, n: u32) !void {
    return self.vtable.dyad_f32(self, op, out, x, y, n);
  }
  pub fn monadI32(self: *GpuCtx, op: MonadOp, out: GpuRange, x: GpuRange, n: u32) !void {
    return self.vtable.monad_i32(self, op, out, x, n);
  }
  pub fn monadF32(self: *GpuCtx, op: MonadOp, out: GpuRange, x: GpuRange, n: u32) !void {
    return self.vtable.monad_f32(self, op, out, x, n);
  }
  // Reduce. `out` must point to one element of the dtype.
  pub fn reduceI32(self: *GpuCtx, op: ReduceOp, out: GpuRange, x: GpuRange, n: u32) !void {
    return self.vtable.reduce_i32(self, op, out, x, n);
  }
  pub fn reduceF32(self: *GpuCtx, op: ReduceOp, out: GpuRange, x: GpuRange, n: u32) !void {
    return self.vtable.reduce_f32(self, op, out, x, n);
  }
  pub fn scanI32(self: *GpuCtx, op: ScanOp, out: GpuRange, x: GpuRange, n: u32) !void {
    return self.vtable.scan_i32(self, op, out, x, n);
  }
  pub fn scanF32(self: *GpuCtx, op: ScanOp, out: GpuRange, x: GpuRange, n: u32) !void {
    return self.vtable.scan_f32(self, op, out, x, n);
  }
};

// No-op backend used by storage-layout tests in value.zig.
pub const StubBackend = struct {
  ctx: GpuCtx,

  pub const vtable: VTable = .{
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

  pub fn init(alloc: std.mem.Allocator) StubBackend {
    return .{ .ctx = .{ .alloc = alloc, .vtable = &vtable } };
  }

  fn freeImpl(_: *GpuCtx, _: GpuRange, _: u32) void {}
  fn allocImpl(_: *GpuCtx, _: u32) anyerror!GpuRange { return .{}; }
  fn readImpl(_: *GpuCtx, _: GpuRange, _: []u8) anyerror!void {}
  fn iotaImpl(_: *GpuCtx, _: GpuRange, _: u32) anyerror!void {}
  fn dyadI32Impl(_: *GpuCtx, _: DyadOp, _: GpuRange, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn dyadF32Impl(_: *GpuCtx, _: DyadOp, _: GpuRange, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn monadI32Impl(_: *GpuCtx, _: MonadOp, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn monadF32Impl(_: *GpuCtx, _: MonadOp, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn reduceI32Impl(_: *GpuCtx, _: ReduceOp, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn reduceF32Impl(_: *GpuCtx, _: ReduceOp, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn scanI32Impl(_: *GpuCtx, _: ScanOp, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
  fn scanF32Impl(_: *GpuCtx, _: ScanOp, _: GpuRange, _: GpuRange, _: u32) anyerror!void {}
};

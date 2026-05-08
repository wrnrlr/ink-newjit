const std = @import("std");
const gpu = @import("gpu");

pub const Loc = gpu.Loc;
pub const GpuCtx = gpu.GpuCtx;
pub const GpuRange = gpu.GpuRange;

pub const GpuMeta = extern struct {
  range: GpuRange,
  ctx:   ?*GpuCtx,
};

pub const Rc = extern struct {
  rc:    u32,
  len:   u32,
  loc:   u32   = @intFromEnum(Loc.cpu),
  flags: u8    = 0,
  _pad:  [3]u8 = .{0, 0, 0},
  pub fn data(r: *Rc, comptime T: type) [*]T {
    return @as([*]T, @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(r) + @sizeOf(Rc), @alignOf(T))));
  }
  pub fn isGpu(r: *const Rc) bool { return r.loc == @intFromEnum(Loc.gpu); }
  pub fn gpuMeta(r: *Rc) *GpuMeta {
    return @ptrFromInt(@intFromPtr(r) + @sizeOf(Rc));
  }
};

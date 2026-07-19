const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("value.zig").V;
const Fn = @import("operator.zig").Fn;

pub const Partial = struct {
  // *anyopaque to avoid a circular type reference: Partial → MemoryPool(Partial) → Partial.
  // Stored as opaque, cast back to *std.heap.MemoryPool(Partial) in deinit.
  pool:  *anyopaque,
  rc:    u32,
  fill:  u8,   // bitmask: bit i set → args[i] is filled
  arity: u8,   // original function arity
  _pad:  u16,
  ref:   Fn,
  args:  [8]V, // .blank = unfilled slot

  pub fn deinit(p: *Partial, alloc: Alloc) void {
    p.rc -= 1;
    if (p.rc == 0) {
      for (0..8) |i| if (p.fill & (@as(u8, 1) << @intCast(i)) != 0) p.args[i].deinit(alloc);
      const Pool = std.heap.MemoryPool(Partial);
      @as(*Pool, @ptrCast(@alignCast(p.pool))).destroy(p);
    }
  }

  pub fn filledCount(p: *const Partial) u8 { return @popCount(p.fill); }
  pub fn remaining(p: *const Partial) u8 { return p.arity - p.filledCount(); }
};

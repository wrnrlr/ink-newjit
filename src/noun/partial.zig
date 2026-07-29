const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("value.zig").V;
const opmod = @import("operator.zig");
const Fn = opmod.Fn;
const MAX_ARGS = opmod.MAX_ARGS;
const ArgMask = opmod.ArgMask;

pub const Partial = struct {
  // *anyopaque to avoid a circular type reference: Partial → MemoryPool(Partial) → Partial.
  // Stored as opaque, cast back to *std.heap.MemoryPool(Partial) in deinit.
  pool:  *anyopaque,
  rc:    u32,
  fill:  ArgMask, // bitmask: bit i set → args[i] is filled
  arity: u8,      // original function arity
  _pad:  u8,
  ref:   Fn,
  args:  [MAX_ARGS]V, // slots ≥ arity are never read; `fill` is the only truth

  pub fn deinit(p: *Partial, alloc: Alloc) void {
    p.rc -= 1;
    if (p.rc == 0) {
      for (0..MAX_ARGS) |i| if (p.fill & (@as(ArgMask, 1) << @intCast(i)) != 0) p.args[i].deinit(alloc);
      const Pool = std.heap.MemoryPool(Partial);
      @as(*Pool, @ptrCast(@alignCast(p.pool))).destroy(p);
    }
  }

  pub fn filledCount(p: *const Partial) u8 { return @popCount(p.fill); }
  pub fn remaining(p: *const Partial) u8 { return p.arity - p.filledCount(); }
};

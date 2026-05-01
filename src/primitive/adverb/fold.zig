const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const K = @import("../../noun/class.zig").K;
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const Op = @import("../../runtime/tape.zig").Op;
const gpu = @import("../../gpu/gpu.zig");
const V = value.V;
const N = value.N;

const REDUCE_GPU_THRESHOLD: usize = 4096;

fn reduceOpForKOp(op: Op) ?gpu.ReduceOp {
  return switch (op) {
    .@"+" => .add,
    .@"*" => .mul,
    .@"&" => .min,
    .@"|" => .max,
    else  => null,
  };
}

// GPU shortcut for f/x where f is a supported builtin and x is a
// GPU-resident I/F vector. Returns null if any precondition fails.
fn tryGpuReduce(vm: *VM, base: V, init: ?V, x: V) ?V {
  if (init != null) return null;
  if (vm.gpu == null) return null;
  if (base.tag() != .func or base.func.getKind() != .builtin) return null;
  const r_op = reduceOpForKOp(base.func.getOp()) orelse return null;
  const g = vm.gpu.?;
  switch (x.tag()) {
    .I => {
      if (!x.I.isGpu() or x.I.ptr.len < REDUCE_GPU_THRESHOLD) return null;
      const n: u32 = @intCast(x.I.ptr.len);
      const out_range = g.allocRange(@sizeOf(i32)) catch return null;
      defer g.free(out_range, @sizeOf(i32));
      g.reduceI32(r_op, out_range, x.I.gpuRange(), n) catch return null;
      var buf: [4]u8 = undefined;
      g.read(out_range, &buf) catch return null;
      return V{ .i = std.mem.readInt(i32, &buf, .little) };
    },
    .F => {
      if (!x.F.isGpu() or x.F.ptr.len < REDUCE_GPU_THRESHOLD) return null;
      const n: u32 = @intCast(x.F.ptr.len);
      const out_range = g.allocRange(@sizeOf(f32)) catch return null;
      defer g.free(out_range, @sizeOf(f32));
      g.reduceF32(r_op, out_range, x.F.gpuRange(), n) catch return null;
      var buf: [4]u8 = undefined;
      g.read(out_range, &buf) catch return null;
      return V{ .f = @bitCast(std.mem.readInt(u32, &buf, .little)) };
    },
    else => return null,
  }
}

pub fn fold(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  if (tryGpuReduce(vm, base, init, x)) |v| return v;

  const n = x.len();

  var accum = if (init) |v| v.ref() else blk: {
    if (n == 0) return .blank;
    break :blk x.at(0);
  };

  const start: usize = if (init != null) 0 else 1;

  if (base.tag() == .func and base.func.getKind() == .lambda) {
    const ref = base.func;
    for (start..n) |i| {
      const item = x.at(i);
      const args = [_]V{ accum, item };
      const next = vm.callLambdaAndRun(ref, &args);
      item.deinit(vm.alloc);
      accum.deinit(vm.alloc);
      accum = next;
    }
    return accum;
  }

  for (start..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ accum, item };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

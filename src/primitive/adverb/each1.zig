const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const gpu = @import("../../gpu/gpu.zig");
const MonadFn = @import("../../util.zig").MonadFn;
const V = value.V;
const N = value.N;

const EACH_GPU_THRESHOLD: usize = 4096;

fn monadOpForOp(op: Op) ?gpu.MonadOp {
  return switch (op) {
    .@"-" => .neg,
    .@"_" => .abs,
    else  => null,
  };
}

// Apply f to each element in x
pub fn each1(vm: *VM, base: V, x: V, f: anytype) !V {
  // GPU shortcut: builtin element-wise monad on a GPU-resident I/F vector.
  if (vm.gpu) |g| {
    if (base.tag() == .func and base.func.getKind() == .builtin) {
      if (monadOpForOp(base.func.getOp())) |m_op| {
        const xt = x.tag();
        if (xt == .I and x.I.isGpu() and x.I.ptr.len >= EACH_GPU_THRESHOLD) {
          const n: u32 = @intCast(x.I.ptr.len);
          const out_range = try g.allocRange(n * @sizeOf(i32));
          try g.monadI32(m_op, out_range, x.I.gpuRange(), n);
          return .{ .I = try N(i32).initGpu(g, out_range, n) };
        }
        if (xt == .F and x.F.isGpu() and x.F.ptr.len >= EACH_GPU_THRESHOLD) {
          const n: u32 = @intCast(x.F.ptr.len);
          const out_range = try g.allocRange(n * @sizeOf(f32));
          try g.monadF32(m_op, out_range, x.F.gpuRange(), n);
          return .{ .F = try N(f32).initGpu(g, out_range, n) };
        }
      }
    }
  }

  const n = x.len();
  var res = try N(V).init(vm.alloc, n);
  errdefer {
    for (res.slice()) |*v| v.deinit(vm.alloc);
    res.deinit(vm.alloc);
  }
  for (0..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{item};
    res.slice()[i] = try f(vm, base, &args);
  }
  return .{ .L = res };
}

const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const gpu = @import("gpu");
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;
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
pub fn each1(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  // GPU shortcut: builtin element-wise monad on a GPU-resident I/F vector.
  if (vm.gpu) |g| {
    if (base.tag() == .func and base.func.getKind() == .builtin) {
      if (monadOpForOp(base.func.getOp())) |m_op| {
        const xt = x.tag();
        if (xt == .I and x.I.isGpu() and x.I.ptr.len >= EACH_GPU_THRESHOLD) {
          const n: u32 = @intCast(x.I.ptr.len);
          const out_range = g.allocRange(n * @sizeOf(i32)) catch return V{ .err = .memory };
          g.monadI32(m_op, out_range, x.I.gpuRange(), n) catch return V{ .err = .memory };
          return .{ .I = N(i32).initGpu(g, out_range, n) catch return V{ .err = .memory } };
        }
        if (xt == .F and x.F.isGpu() and x.F.ptr.len >= EACH_GPU_THRESHOLD) {
          const n: u32 = @intCast(x.F.ptr.len);
          const out_range = g.allocRange(n * @sizeOf(f32)) catch return V{ .err = .memory };
          g.monadF32(m_op, out_range, x.F.gpuRange(), n) catch return V{ .err = .memory };
          return .{ .F = N(f32).initGpu(g, out_range, n) catch return V{ .err = .memory } };
        }
      }
    }
  }

  const n = x.len();
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  const is_lambda = base.tag() == .func and base.func.getKind() == .lambda;
  const lambda_ref = if (is_lambda) base.func else undefined;
  for (0..n) |i| {
    const item = x.at(i);
    const args = [_]V{item};
    res.slice()[i] = if (is_lambda) vm.callLambdaAndRun(lambda_ref, &args) else f(vm, base, &args);
    item.deinit(vm.alloc);
  }
  return promote(vm.alloc, res);
}

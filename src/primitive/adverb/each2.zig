const std = @import("std");
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const gpu = @import("../../gpu/gpu.zig");
const util = @import("../../util.zig");
const V = value.V;
const N = value.N;

const EACH_GPU_THRESHOLD: usize = 4096;

fn dyadOpForOp(op: Op) ?gpu.DyadOp {
  return switch (op) {
    .@"+" => .add, .@"-" => .sub, .@"*" => .mul, .@"%" => .div,
    .@"&" => .min, .@"|" => .max,
    else  => null,
  };
}

pub fn each2(vm: *VM, base: V, xs: []const V, f: util.ApplyFn) V {
  // GPU shortcut: builtin element-wise dyad on two GPU-resident I/F vectors
  // of equal length. Only applicable for the binary (2-arg) case.
  if (vm.gpu) |g| if (xs.len == 2) {
    if (base.tag() == .func and base.func.getKind() == .builtin) {
      if (dyadOpForOp(base.func.getOp())) |d_op| {
        const x = xs[0];
        const y = xs[1];
        const xt = x.tag();
        const yt = y.tag();
        if (xt == .I and yt == .I and x.I.isGpu() and y.I.isGpu() and
            x.I.ptr.len >= EACH_GPU_THRESHOLD and x.I.ptr.len == y.I.ptr.len) {
          const n: u32 = @intCast(x.I.ptr.len);
          const out_range = g.allocRange(n * @sizeOf(i32)) catch return V{ .err = .memory };
          g.dyadI32(d_op, out_range, x.I.gpuRange(), y.I.gpuRange(), n) catch return V{ .err = .memory };
          return .{ .I = N(i32).initGpu(g, out_range, n) catch return V{ .err = .memory } };
        }
        if (xt == .F and yt == .F and x.F.isGpu() and y.F.isGpu() and
            x.F.ptr.len >= EACH_GPU_THRESHOLD and x.F.ptr.len == y.F.ptr.len) {
          const n: u32 = @intCast(x.F.ptr.len);
          const out_range = g.allocRange(n * @sizeOf(f32)) catch return V{ .err = .memory };
          g.dyadF32(d_op, out_range, x.F.gpuRange(), y.F.gpuRange(), n) catch return V{ .err = .memory };
          return .{ .F = N(f32).initGpu(g, out_range, n) catch return V{ .err = .memory } };
        }
      }
    }
  };

  // Multi-arg each: zip all args together, all must be same length
  const n = xs[0].len();
  for (xs[1..]) |x| {
    if (x.len() != n) return V{ .err = .length };
  }

  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };

  var call_args = vm.alloc.alloc(V, xs.len) catch {
    res.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  defer vm.alloc.free(call_args);

  for (0..n) |i| {
    for (xs, 0..) |x, j| call_args[j] = x.at(i);
    defer for (call_args) |a| a.deinit(vm.alloc);
    res.slice()[i] = f(vm, base, call_args);
  }
  return .{ .L = res };
}

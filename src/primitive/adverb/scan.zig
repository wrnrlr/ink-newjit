const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const gpu = @import("../../gpu/gpu.zig");
const util = @import("../../util.zig");
const V = value.V;
const N = value.N;

const SCAN_GPU_THRESHOLD: usize = 4096;

fn scanOpForKOp(op: Op) ?gpu.ScanOp {
  return switch (op) {
    .@"+" => .add,
    .@"*" => .mul,
    else  => null,
  };
}

fn tryGpuScan(vm: *VM, base: V, init: ?V, x: V) ?V {
  if (init != null) return null;
  if (vm.gpu == null) return null;
  if (base.tag() != .func or base.func.getKind() != .builtin) return null;
  const s_op = scanOpForKOp(base.func.getOp()) orelse return null;
  const g = vm.gpu.?;
  switch (x.tag()) {
    .I => {
      if (!x.I.isGpu() or x.I.ptr.len < SCAN_GPU_THRESHOLD) return null;
      const n: u32 = @intCast(x.I.ptr.len);
      const out_range = g.allocRange(n * @sizeOf(i32)) catch return null;
      g.scanI32(s_op, out_range, x.I.gpuRange(), n) catch return null;
      return .{ .I = N(i32).initGpu(g, out_range, n) catch return null };
    },
    .F => {
      if (!x.F.isGpu() or x.F.ptr.len < SCAN_GPU_THRESHOLD) return null;
      const n: u32 = @intCast(x.F.ptr.len);
      const out_range = g.allocRange(n * @sizeOf(f32)) catch return null;
      g.scanF32(s_op, out_range, x.F.gpuRange(), n) catch return null;
      return .{ .F = N(f32).initGpu(g, out_range, n) catch return null };
    },
    else => return null,
  }
}

// scan: collect running accumulations
// +\1 2 3 → 1 3 6  (n results, starting from x[0])
pub fn scan(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  if (tryGpuScan(vm, base, init, x)) |v| return v;

  const n = x.len();
  if (n == 0) return .{ .L = N(V).init(vm.alloc, 0) catch return V{ .err = .memory } };

  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };

  var accum = if (init) |iv| iv.ref() else x.at(0);
  const start: usize = if (init != null) 0 else 1;

  // For unseeded: first element is x[0] (already accum), store it
  if (init == null) res.slice()[0] = accum.ref();

  var ri: usize = if (init != null) 0 else 1;
  for (start..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ accum, item };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
    res.slice()[ri] = accum.ref();
    ri += 1;
  }
  accum.deinit(vm.alloc);
  return .{ .L = res };
}

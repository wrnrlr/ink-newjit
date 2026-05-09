const std = @import("std");
const Alloc = std.mem.Allocator;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const gpu = @import("gpu");
const util = @import("../../util.zig");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

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

// CPU fast path: builtin prefix-scan on a typed CPU array.
// Returns a typed N(T) result instead of N(V), avoids per-element boxing.
inline fn cpuScan(alloc: Alloc, op: Op, x: V) ?V {
  switch (x.tag()) {
    .I => if (!x.I.isGpu()) {
      const s = x.I.slice();
      const n = s.len;
      if (n == 0) return .{ .I = N(i32).init(alloc, 0) catch return V{ .err = .memory } };
      const out = N(i32).init(alloc, n) catch return V{ .err = .memory };
      switch (op) {
        .@"+" => {
          var acc: i32 = 0;
          for (out.slice(), s) |*r, v| { acc +%= v; r.* = acc; }
          return .{ .I = out };
        },
        .@"*" => {
          var acc: i32 = 1;
          for (out.slice(), s) |*r, v| { acc *%= v; r.* = acc; }
          return .{ .I = out };
        },
        .@"&" => {
          var acc = s[0];
          out.slice()[0] = acc;
          for (out.slice()[1..], s[1..]) |*r, v| { acc = @min(acc, v); r.* = acc; }
          return .{ .I = out };
        },
        .@"|" => {
          var acc = s[0];
          out.slice()[0] = acc;
          for (out.slice()[1..], s[1..]) |*r, v| { acc = @max(acc, v); r.* = acc; }
          return .{ .I = out };
        },
        else => { out.deinit(alloc); },
      }
    },
    .F => if (!x.F.isGpu()) {
      const s = x.F.slice();
      const n = s.len;
      if (n == 0) return .{ .F = N(f32).init(alloc, 0) catch return V{ .err = .memory } };
      const out = N(f32).init(alloc, n) catch return V{ .err = .memory };
      switch (op) {
        .@"+" => {
          var acc: f32 = 0;
          for (out.slice(), s) |*r, v| { acc += v; r.* = acc; }
          return .{ .F = out };
        },
        .@"*" => {
          var acc: f32 = 1;
          for (out.slice(), s) |*r, v| { acc *= v; r.* = acc; }
          return .{ .F = out };
        },
        .@"&" => {
          var acc = s[0];
          out.slice()[0] = acc;
          for (out.slice()[1..], s[1..]) |*r, v| { acc = @min(acc, v); r.* = acc; }
          return .{ .F = out };
        },
        .@"|" => {
          var acc = s[0];
          out.slice()[0] = acc;
          for (out.slice()[1..], s[1..]) |*r, v| { acc = @max(acc, v); r.* = acc; }
          return .{ .F = out };
        },
        else => { out.deinit(alloc); },
      }
    },
    else => {},
  }
  return null;
}

// scan: collect running accumulations
// +\1 2 3 → 1 3 6  (n results, starting from x[0])
pub fn scan(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  if (tryGpuScan(vm, base, init, x)) |v| return v;

  // CPU fast path: no init, builtin op, typed array — returns typed result.
  if (init == null and base.tag() == .func and base.func.getKind() == .builtin) {
    if (cpuScan(vm.alloc, base.func.getOp(), x)) |v| return v;
  }

  const n = x.len();
  if (n == 0) return vm.aList() catch return V{ .err = .memory };

  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };

  var accum = if (init) |iv| iv.ref() else x.at(0);
  const start: usize = if (init != null) 0 else 1;

  // For unseeded: first element is x[0] (already accum), store it
  if (init == null) res.slice()[0] = accum.ref();

  var ri: usize = if (init != null) 0 else 1;
  const is_lambda = base.tag() == .func and base.func.getKind() == .lambda;
  const lambda_ref = if (is_lambda) base.func else undefined;
  for (start..n) |i| {
    const item = x.at(i);
    const args = [_]V{ accum, item };
    const next = if (is_lambda) vm.callLambdaAndRun(lambda_ref, &args) else f(vm, base, &args);
    item.deinit(vm.alloc);
    accum.deinit(vm.alloc);
    accum = next;
    res.slice()[ri] = accum.ref();
    ri += 1;
  }
  accum.deinit(vm.alloc);
  return .{ .L = res };
}

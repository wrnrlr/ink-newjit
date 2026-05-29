const std = @import("std");
const Alloc = std.mem.Allocator;
const Op2 = @import("../../noun/operator.zig").Op2;
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;

// CPU fast path: builtin prefix-scan on a typed CPU array.
// Returns a typed N(T) result instead of N(V), avoids per-element boxing.
inline fn cpuScan(alloc: Alloc, op: Op2, x: V) ?V {
  switch (x.tag()) {
    .I => {
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
    .F => {
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
  // CPU fast path: no init, builtin op, typed array — returns typed result.
  if (init == null and base.tag() == .func and base.func.getKind() == .builtin) {
    if (base.func.arity == 2)
      if (cpuScan(vm.alloc, base.func.getOp2(), x)) |v| return v;
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
  return promote(vm.alloc, res);
}

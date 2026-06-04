// Fused +/ reducer. Bypasses derived Fn allocation when the optimizer
// rewrites `+/x` into `Apply1 +/`. Mirrors the cpuReduce fast paths in
// fold.zig but is dispatched directly via monad_table.

const std = @import("std");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const dispatch = @import("../dispatch.zig");
const reduce = @import("reduce.zig");

pub const Sum = struct {
  pub const op = .@"+/";
  _B: util.MonadFn = sumB,
  _I: util.MonadFn = sumI,
  _F: util.MonadFn = sumF,
  _L: util.MonadFn = sumL,
};

fn sumB(_: *VM, x: V) V {
  const s = x.B.slice();
  var acc: i32 = 0;
  for (s) |v| if (v) { acc += 1; };
  return .{ .i = acc };
}

fn sumI(_: *VM, x: V) V {
  const s = x.I.slice();
  if (s.len == 0) return .blank;
  return .{ .i = reduce.sum(i32, s) };
}

fn sumF(_: *VM, x: V) V {
  const s = x.F.slice();
  if (s.len == 0) return .blank;
  return .{ .f = reduce.sum(f32, s) };
}

fn sumL(vm: *VM, x: V) V {
  const n = x.len();
  if (n == 0) return .blank;
  var accum = x.at(0);
  for (1..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const next = dispatch.dispatch2(vm, .@"+", accum, item);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

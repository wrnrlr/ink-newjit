// Fused */ reducer. See sum.zig.
const std = @import("std");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const dispatch = @import("../dispatch.zig");
const reduce = @import("reduce.zig");

pub const Product = struct {
  pub const op = .@"*/";
  _I: util.MonadFn = prodI,
  _F: util.MonadFn = prodF,
  _L: util.MonadFn = prodL,
};

fn prodI(_: *VM, x: V) V {
  const s = x.I.slice();
  if (s.len == 0) return .blank;
  return .{ .i = reduce.product(i32, s) };
}

fn prodF(_: *VM, x: V) V {
  const s = x.F.slice();
  if (s.len == 0) return .blank;
  return .{ .f = reduce.product(f32, s) };
}

fn prodL(vm: *VM, x: V) V {
  const n = x.len();
  if (n == 0) return .blank;
  var accum = x.at(0);
  for (1..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const next = dispatch.dispatch2(vm, .@"*", accum, item);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

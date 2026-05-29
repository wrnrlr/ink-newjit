// Fused &/ reducer (min on numeric, all-AND on bool).
const std = @import("std");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const dispatch = @import("../dispatch.zig");

pub const Min = struct {
  pub const op = .@"&/";
  _B: util.MonadFn = minB,
  _I: util.MonadFn = minI,
  _F: util.MonadFn = minF,
  _L: util.MonadFn = minL,
};

fn minB(_: *VM, x: V) V {
  const s = x.B.slice();
  if (s.len == 0) return .blank;
  var acc = s[0];
  for (s[1..]) |v| acc = acc and v;
  return .{ .b = acc };
}

fn minI(_: *VM, x: V) V {
  const s = x.I.slice();
  if (s.len == 0) return .blank;
  var acc: i32 = s[0];
  for (s[1..]) |v| acc = @min(acc, v);
  return .{ .i = acc };
}

fn minF(_: *VM, x: V) V {
  const s = x.F.slice();
  if (s.len == 0) return .blank;
  var acc: f32 = s[0];
  for (s[1..]) |v| acc = @min(acc, v);
  return .{ .f = acc };
}

fn minL(vm: *VM, x: V) V {
  const n = x.len();
  if (n == 0) return .blank;
  var accum = x.at(0);
  for (1..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const next = dispatch.dispatch2(vm, .@"&", accum, item);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

// Fused |/ reducer (max on numeric, any-OR on bool).
const std = @import("std");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const dispatch = @import("../dispatch.zig");

pub const Max = struct {
  pub const op = .@"|/";
  _B: util.MonadFn = maxB,
  _I: util.MonadFn = maxI,
  _F: util.MonadFn = maxF,
  _L: util.MonadFn = maxL,
};

fn maxB(_: *VM, x: V) V {
  const s = x.B.slice();
  if (s.len == 0) return .blank;
  var acc = s[0];
  for (s[1..]) |v| acc = acc or v;
  return .{ .b = acc };
}

fn maxI(_: *VM, x: V) V {
  const s = x.I.slice();
  if (s.len == 0) return .blank;
  var acc: i32 = s[0];
  for (s[1..]) |v| acc = @max(acc, v);
  return .{ .i = acc };
}

fn maxF(_: *VM, x: V) V {
  const s = x.F.slice();
  if (s.len == 0) return .blank;
  var acc: f32 = s[0];
  for (s[1..]) |v| acc = @max(acc, v);
  return .{ .f = acc };
}

fn maxL(vm: *VM, x: V) V {
  const n = x.len();
  if (n == 0) return .blank;
  var accum = x.at(0);
  for (1..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const next = dispatch.dispatch2(vm, .@"|", accum, item);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const N = value.N;

// stencil: n f': x — apply f to each window of size n
// 3{x,"."}':"abcde" → ("abc.";"bcd.";"cde.")
pub fn stencil(vm: *VM, xn: V, base: V, x: V, callFn: anytype) !V {
  std.debug.assert(xn.tag()==.i);
  std.debug.assert(base.tag()==.func);
  std.debug.assert(x.isVec() or x.tag()==.L);
  const n = xn.i;
  const xlen = x.len();
  if (xlen < n) return .{ .L = try N(V).init(vm.alloc, 0) };
  const count = xlen - n + 1;
  var res = try N(V).init(vm.alloc, count);
  errdefer {
    for (res.slice()) |*v| v.deinit(vm.alloc);
    res.deinit(vm.alloc);
  }
  for (0..count) |i| {
    var win = try N(V).init(vm.alloc, n);
    for (0..n) |j| win.slice()[j] = x.at(i + j);
    const win_v = V{ .L = win };
    defer win_v.deinit(vm.alloc);
    const args = [_]V{win_v};
    res.slice()[i] = try callFn(vm, base, &args);
  }
  return .{ .L = res };
}

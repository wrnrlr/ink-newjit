const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const N = value.N;

// window: n': x — sliding windows of size n
// 3':"abcdef" → ("abc";"bcd";"cde";"def")
pub fn window(vm: *VM, xn: V, x: V) !V {
  std.debug.assert(xn.tag()==.i);
  std.debug.assert(x.isVec() or x.tag()==.L);
  const n:usize = @intCast(xn.i);
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
    res.slice()[i] = .{ .L = win };
  }
  return .{ .L = res };
}

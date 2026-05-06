const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const N = value.N;

// window: n': x — sliding windows of size n
// 3':"abcdef" → ("abc";"bcd";"cde";"def")
pub fn window(vm: *VM, xn: V, x: V) V {
  std.debug.assert(xn.tag()==.i);
  std.debug.assert(x.isVec() or x.tag()==.L);
  const n:usize = @intCast(xn.i);
  const xlen = x.len();
  if (xlen < n) return vm.aList() catch return .{ .err = .memory };
  const count = xlen - n + 1;
  var res = N(V).init(vm.alloc, count) catch return .{ .err = .memory };
  @memset(res.slice(), .blank);
  for (0..count) |i| {
    res.slice()[i] = makeWindow(vm.alloc, x, i, n) catch return .{ .err = .memory };
  }
  return .{ .L = res };
}

pub fn makeWindow(alloc: Alloc, x: V, start: usize, n: usize) !V {
  inline for ([_]K{ .C, .I, .F, .B }) |k| {
    if (x.tag() == k) {
      const out = try N(K.backing(k)).init(alloc, n);
      @memcpy(out.slice(), x.unwrap(k).slice()[start .. start + n]);
      return V.wrap(k, out);
    }
  }
  const out = try N(V).init(alloc, n);
  for (0..n) |j| out.slice()[j] = x.at(start + j);
  return .{ .L = out };
}

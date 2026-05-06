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
  switch (x.tag()) {
    .C => for (0..count) |i| {
      var win = N(u8).init(vm.alloc, n) catch return .{ .err = .memory };
      @memcpy(win.slice(), x.C.slice()[i .. i + n]);
      res.slice()[i] = .{ .C = win };
    },
    .I => for (0..count) |i| {
      var win = N(i32).init(vm.alloc, n) catch return .{ .err = .memory };
      @memcpy(win.slice(), x.I.slice()[i .. i + n]);
      res.slice()[i] = .{ .I = win };
    },
    .F => for (0..count) |i| {
      var win = N(f32).init(vm.alloc, n) catch return .{ .err = .memory };
      @memcpy(win.slice(), x.F.slice()[i .. i + n]);
      res.slice()[i] = .{ .F = win };
    },
    .B => for (0..count) |i| {
      var win = N(bool).init(vm.alloc, n) catch return .{ .err = .memory };
      @memcpy(win.slice(), x.B.slice()[i .. i + n]);
      res.slice()[i] = .{ .B = win };
    },
    else => for (0..count) |i| {
      var win = N(V).init(vm.alloc, n) catch return .{ .err = .memory };
      for (0..n) |j| win.slice()[j] = x.at(i + j);
      res.slice()[i] = .{ .L = win };
    },
  }
  return .{ .L = res };
}

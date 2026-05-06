const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const N = value.N;

// stencil: f'[n;x] — apply f to each sliding window of size n
// {x,"."}'[3;"abcde"] → ("abc.";"bcd.";"cde.")
pub fn stencil(vm: *VM, xn: V, base: V, x: V, callFn: anytype) V {
  if (xn.i <= 0) return .{ .err = .domain };
  const n: usize = @intCast(xn.i);
  const xlen = x.len();
  if (xlen < n) return vm.aList() catch return V{ .err = .memory };
  const count = xlen - n + 1;
  var res = N(V).init(vm.alloc, count) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (0..count) |i| {
    const win_v = makeWindow(vm.alloc, x, i, n) catch {
      (V{ .L = res }).deinit(vm.alloc);
      return V{ .err = .memory };
    };
    defer win_v.deinit(vm.alloc);
    const args = [_]V{win_v};
    res.slice()[i] = callFn(vm, base, &args);
  }
  return .{ .L = res };
}

fn makeWindow(alloc: Alloc, x: V, start: usize, n: usize) !V {
  switch (x.tag()) {
    .C => {
      const out = try N(u8).init(alloc, n);
      @memcpy(out.slice(), x.C.slice()[start .. start + n]);
      return .{ .C = out };
    },
    .I => {
      const out = try N(i32).init(alloc, n);
      @memcpy(out.slice(), x.I.slice()[start .. start + n]);
      return .{ .I = out };
    },
    .F => {
      const out = try N(f32).init(alloc, n);
      @memcpy(out.slice(), x.F.slice()[start .. start + n]);
      return .{ .F = out };
    },
    .B => {
      const out = try N(bool).init(alloc, n);
      @memcpy(out.slice(), x.B.slice()[start .. start + n]);
      return .{ .B = out };
    },
    else => {
      const out = try N(V).init(alloc, n);
      for (0..n) |j| out.slice()[j] = x.at(start + j);
      return .{ .L = out };
    },
  }
}

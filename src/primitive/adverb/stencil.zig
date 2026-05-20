const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const makeWindow = @import("window.zig").makeWindow;
const promote = @import("../promote.zig").promote;

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
  return promote(vm.alloc, res);
}

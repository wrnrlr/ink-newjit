const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const value = @import("../../noun/value.zig");
const V = value.V;
const N = value.N;

pub fn eachright(vm: *VM, base: V, x: V, y: V, f: util.ApplyFn) V {
  const n = y.len();
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  for (0..n) |i| {
    const item = y.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ x, item };
    res.slice()[i] = f(vm, base, &args);
  }
  return .{ .L = res };
}

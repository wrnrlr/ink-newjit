const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

pub fn eachleft(vm: *VM, base: V, x: V, y: V, f: util.ApplyFn) V {
  const n = x.len();
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  for (0..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ item, y };
    res.slice()[i] = f(vm, base, &args);
  }
  return .{ .L = res };
}

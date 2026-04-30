const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const DyadFn = @import("../../util.zig").DyadFn;
const value = @import("../../noun/value.zig");
const V = value.V;
const N = value.N;

pub fn eachleft(vm: *VM, base: V, x: V, y: V, f: anytype) !V {
  const n = x.len();
  var res = try N(V).init(vm.alloc, n);
  errdefer {
    for (res.slice()) |*v| v.deinit(vm.alloc);
    res.deinit(vm.alloc);
  }
  for (0..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ item, y };
    res.slice()[i] = try f(vm, base, &args);
  }
  return .{ .L = res };
}

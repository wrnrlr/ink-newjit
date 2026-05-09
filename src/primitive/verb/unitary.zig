const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

pub const Unitary = struct {
  pub const op = .@"=";
  _i: util.MonadFn = unitary,
};

fn unitary(vm: *VM, x: V) V {
  if (x.i < 0) return .{ .err = .domain };
  const size: usize = @intCast(x.i);
  const res = N(V).init(vm.alloc, size) catch return V{ .err = .memory };
  for (0..size) |i| {
    const row = N(i32).init(vm.alloc, size) catch return V{ .err = .memory };
    const row_slice = row.slice();
    @memset(row_slice, 0);
    row_slice[i] = 1;
    res.slice()[i] = .{ .I = row };
  }
  return .{ .L = res };
}

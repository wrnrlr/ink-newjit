const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const N = value.N;
const V = value.V;

pub const Unitary = struct {
  pub const op = .@"=";
  _i: util.MonadFn = unitary,
};

fn unitary(vm: *VM, x: V) !V {
  if (x.i < 0) return .{ .err = .domain };
  const size: usize = @intCast(x.i);
  const res = try N(V).init(vm.alloc, size);
  for (0..size) |i| {
    const row = try N(i32).init(vm.alloc, size);
    const row_slice = row.slice();
    @memset(row_slice, 0);
    row_slice[i] = 1;
    res.slice()[i] = .{ .I = row };
  }
  return .{ .L = res };
}

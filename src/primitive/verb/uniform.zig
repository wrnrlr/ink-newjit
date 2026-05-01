const std = @import("std");
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;

const V = value.V;
const N = value.N;

pub const Uniform = struct {
  pub const op = .@"?";

  _i: util.MonadFn = uniform,
};

fn uniform(vm: *VM, x: V) V {
  const i = x.i;
  if (i < 0) return .{ .err = .domain };
  const size: usize = @intCast(i);
  const res = N(f32).init(vm.alloc, size) catch return V{ .err = .memory };
  const random = vm.prng.random();
  for (res.slice()) |*val| {
    val.* = random.float(f32);
  }
  return .{ .F = res };
}

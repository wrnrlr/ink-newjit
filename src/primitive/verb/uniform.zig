const std = @import("std");
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;

const V = value.V;
const N = value.N;

pub const UniformOp = struct {
  _i: util.MonadFn = uniform,
};

fn uniform(vm: *VM, x: V) V {
  if (x.i < 0) return .{ .err = .domain };
  const size: usize = @intCast(x.i);
  const F = N(f32).init(vm.alloc, size) catch return .{ .err = .memory };
  const random = vm.prng.random();
  for (F.slice()) |*v| v.* = random.float(f32);
  return .{ .F = F };
}

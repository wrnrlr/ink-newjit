const std = @import("std");
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const promote = @import("../promote.zig").promote;

const V = value.V;
const N = value.N;

pub const Random = struct {
  pub const op = .@"?";
  _i_I: util.DyadFn = rand,
  _i_F: util.DyadFn = rand,
  _i_S: util.DyadFn = rand,
  _i_C: util.DyadFn = rand,
  _i_B: util.DyadFn = rand,
  _i_T: util.DyadFn = rand,
  _i_D: util.DyadFn = rand,
  _i_L: util.DyadFn = rand,
};

fn rand(vm: *VM, x: V, y: V) !V {
  const n = y.len();
  const count_abs = @abs(x.i);
  const count: usize = @intCast(count_abs);

  if (x.i >= 0) {
    // Roll: i random selections from y (with replacement)
    if (n == 0) return .{ .err = .length };
    const res = try N(V).init(vm.alloc, count);
    const random = vm.prng.random();
    for (res.slice()) |*val| {
      const idx = random.uintLessThan(usize, n);
      val.* = y.at(idx);
    }
    return try promote(vm.alloc, res);
  } else {
    // Deal: |i| unique selections from y (without replacement)
    if (count > n) return .{ .err = .length };

    var indices = try vm.alloc.alloc(usize, n);
    defer vm.alloc.free(indices);
    for (indices, 0..) |*idx, j| idx.* = j;

    const random = vm.prng.random();
    for (0..count) |j| {
      const swap_idx = j + random.uintLessThan(usize, n - j);
      const tmp = indices[j];
      indices[j] = indices[swap_idx];
      indices[swap_idx] = tmp;
    }

    const res = try N(V).init(vm.alloc, count);
    for (res.slice(), 0..) |*v, j| {
      v.* = y.at(indices[j]);
    }
    return try promote(vm.alloc, res);
  }
}

const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const K = @import("../../noun/class.zig").K;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

// Take creates a new array by selecting the first $x$ elements of $y$ (if $x$ is positive)
// or the last $x$ elements (if $x$ is negative).
// Example: 3#1 2 3 4 5 results in 1 2 3.
pub const Take = struct {
  pub const op = .@"#";
  _i_B: util.DyadFn = takeVec(.B),
  _i_I: util.DyadFn = takeVec(.I),
  _i_F: util.DyadFn = takeVec(.F),
  _i_S: util.DyadFn = takeVec(.S),
  _i_C: util.DyadFn = takeVec(.C),
  _i_L: util.DyadFn = takeList,
};

/// Public entry point used by pair.zig for atom broadcasting.
pub fn take(vm: *VM, x: V, y: V) !V {
  return switch (y) {
    .B => takeVec(.B)(vm, x, y),
    .I => takeVec(.I)(vm, x, y),
    .F => takeVec(.F)(vm, x, y),
    .S => takeVec(.S)(vm, x, y),
    .C => takeVec(.C)(vm, x, y),
    .L => takeList(vm, x, y),
    else => @panic("Take only allowed on vector and list types"),
  };
}

fn takeVec(comptime yk: K) util.DyadFn {
  return struct {
    fn f(vm: *VM, x: V, y: V) !V {
      const T = K.backing(yk);
      const b = @field(y, @tagName(yk));
      const n = b.ptr.len;
      if (n == 0) return y.ref();
      const count: usize = @intCast(@abs(x.i));
      const res = try N(T).init(vm.alloc, count);
      const src = b.slice();
      const dst = res.slice();
      if (x.i >= 0) {
        for (0..count) |j| dst[j] = src[j % n];
      } else {
        for (0..count) |j| {
          const idx = (n * count + j + n - (count % n)) % n;
          dst[j] = src[idx];
        }
      }
      if (yk == .L) return try util.promote(vm.alloc, res);
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}

fn takeList(vm: *VM, x: V, y: V) !V {
  const n = y.len();
  if (n == 0) return y.ref();
  const count: usize = @intCast(@abs(x.i));
  const res = try N(V).init(vm.alloc, count);
  if (x.i >= 0) {
    for (0..count) |j| res.slice()[j] = y.at(j % n);
  } else {
    for (0..count) |j| {
      const idx = (n * count + j + n - (count % n)) % n;
      res.slice()[j] = y.at(idx);
    }
  }
  return try promote(vm.alloc, res);
}

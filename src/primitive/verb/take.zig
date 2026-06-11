const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

// Take creates a new array by selecting the first $x$ elements of $y$ (if $x$ is positive)
// or the last $x$ elements (if $x$ is negative).
// Example: 3#1 2 3 4 5 results in 1 2 3.
pub const Take = struct {
  pub const op = .@"#";
  _i_B: VM.Dyad = takeVec(.B),
  _i_I: VM.Dyad = takeVec(.I),
  _i_F: VM.Dyad = takeVec(.F),
  _i_S: VM.Dyad = takeVec(.S),
  _i_C: VM.Dyad = takeVec(.C),
  _i_L: VM.Dyad = takeList,
  _i_i: VM.Dyad = takeScalarInt,
  _i_f: VM.Dyad = takeScalarFloat,
};

fn takeScalarInt(vm: *VM, x: V, y: V) V {
  const count: usize = @intCast(@abs(x.i));
  const res = N(i32).init(vm.alloc, count) catch return V{ .err = .memory };
  for (res.slice()) |*v| v.* = y.i;
  return .{ .I = res };
}

fn takeScalarFloat(vm: *VM, x: V, y: V) V {
  const count: usize = @intCast(@abs(x.i));
  const res = N(f32).init(vm.alloc, count) catch return V{ .err = .memory };
  for (res.slice()) |*v| v.* = y.f;
  return .{ .F = res };
}

/// Public entry point used by pair.zig for atom broadcasting.
pub fn take(vm: *VM, x: V, y: V) V {
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

fn takeVec(comptime yk: K) VM.Dyad {
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const T = K.backing(yk);
      const b = @field(y, @tagName(yk));
      const n = b.ptr.len;
      if (n == 0) return y.ref();
      const count: usize = @intCast(@abs(x.i));
      const res = N(T).init(vm.alloc, count) catch return V{ .err = .memory };
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
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}

fn takeList(vm: *VM, x: V, y: V) V {
  const n = y.len();
  if (n == 0) return y.ref();
  const count: usize = @intCast(@abs(x.i));
  const res = N(V).init(vm.alloc, count) catch return V{ .err = .memory };
  if (x.i >= 0) {
    for (0..count) |j| res.slice()[j] = y.at(j % n);
  } else {
    for (0..count) |j| {
      const idx = (n * count + j + n - (count % n)) % n;
      res.slice()[j] = y.at(idx);
    }
  }
  return promote(vm.alloc, res);
}

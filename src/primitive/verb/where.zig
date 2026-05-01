const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Where = struct {
  pub const op = .@"&";
  _b: util.MonadFn = whereB,
  _i: util.MonadFn = whereI,
  _B: util.MonadFn = whereBVec,
  _I: util.MonadFn = whereIVec,
};

fn whereB(vm: *VM, x: V) V {
  return if (x.b) .{ .i = 1 } else .{ .I = N(i32).zeros(vm.alloc, 0) catch return V{ .err = .memory } };
}

fn whereI(vm: *VM, x: V) V {
  if (x.i < 0) return .{ .err = .domain };
  return .{ .I = N(i32).zeros(vm.alloc, @intCast(x.i)) catch return V{ .err = .memory } };
}

fn whereBVec(vm: *VM, x: V) V {
  const x_slice = x.B.slice();
  var total: usize = 0;
  for (x_slice) |e| total += @intFromBool(e);
  const res = N(i32).init(vm.alloc, total) catch return V{ .err = .memory };
  var idx: usize = 0;
  for (x_slice) |elem| {
    if (elem) {
      res.slice()[idx] = @intFromBool(elem);
      idx += 1;
    }
  }
  return .{ .I = res };
}

fn whereIVec(vm: *VM, x: V) V {
  const x_slice = x.I.slice();
  for (x_slice) |n| if (n < 0) return .{ .err = .domain };
  var total: usize = 0;
  for (x_slice) |e| total += @intCast(e);
  const res = N(i32).init(vm.alloc, total) catch return V{ .err = .memory };
  var idx: usize = 0;
  for (x_slice, 0..) |elem, i| {
    const count: usize = @intCast(elem);
    for (0..count) |_| {
      res.slice()[idx] = @intCast(i);
      idx += 1;
    }
  }
  return .{ .I = res };
}

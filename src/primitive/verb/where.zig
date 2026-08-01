const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

pub const Where = struct {
  pub const op = .@"&";
  _b: VM.Monad = whereB,
  _i: VM.Monad = whereI,
  _B: VM.Monad = whereBVec,
  _I: VM.Monad = whereIVec,
  _L: VM.Monad = whereList,
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
  for (x_slice, 0..) |elem, i| {
    if (elem) {
      res.slice()[idx] = @intCast(i);
      idx += 1;
    }
  }
  return .{ .I = res };
}

// Where on a general list. An EMPTY one is the case that matters: `f'(0#0)` and
// friends hand back an empty `L`, and `&` on it has to be the empty index vector
// — no element is true — not a type error. A non-empty list still counts, as
// long as every element is a boolean or a non-negative int.
fn whereList(vm: *VM, x: V) V {
  const items = x.L.slice();
  var total: usize = 0;
  for (items) |e| switch (e) {
    .b => |v| total += @intFromBool(v),
    .i => |v| { if (v < 0) return .{ .err = .domain }; total += @intCast(v); },
    else => return .{ .err = .@"type" },
  };
  const res = N(i32).init(vm.alloc, total) catch return V{ .err = .memory };
  var idx: usize = 0;
  for (items, 0..) |e, i| {
    const count: usize = switch (e) {
      .b => |v| @intFromBool(v),
      .i => |v| @intCast(v),
      else => unreachable,
    };
    for (0..count) |_| {
      res.slice()[idx] = @intCast(i);
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

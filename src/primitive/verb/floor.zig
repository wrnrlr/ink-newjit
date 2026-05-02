const std = @import("std");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Floor = struct {
  pub const op = .@"_";
  _b: util.MonadFn = identity,
  _i: util.MonadFn = identity,
  
  _B: util.MonadFn = identity,
  _I: util.MonadFn = identity,
  
  _f: util.MonadFn = floor_f,
  _F: util.MonadFn = floor_F,
};

fn identity(_: *VM, x: V) V { return x; }

fn floor_f(_: *VM, x: V) V {
  return .{ .i = @intFromFloat(std.math.floor(x.f)) };
}

fn floor_F(vm: *VM, x: V) V {
  const res = N(i32).init(vm.alloc, x.F.ptr.len) catch return V{ .err = .memory };
  for (x.F.slice(), res.slice()) |v, *r| r.* = @intFromFloat(std.math.floor(v));
  return .{ .I = res };
}

const std = @import("std");
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Fill = struct {
  pub const op = .@"^";
  
  _b_B: util.DyadFn = fillVec(.b), // identity
  _i_I: util.DyadFn = fillVec(.i),
  _f_F: util.DyadFn = fillVec(.f),
  _s_S: util.DyadFn = fillVec(.s),
  _c_C: util.DyadFn = fillVec(.c),
  
  _i_F: util.DyadFn = fillPromote(.F),
  _f_I: util.DyadFn = fillPromote(.I),
  
  _b_L: util.DyadFn = fillList,
  _i_L: util.DyadFn = fillList,
  _f_L: util.DyadFn = fillList,
  _s_L: util.DyadFn = fillList,
  _c_L: util.DyadFn = fillList,
};

fn fillVec(comptime xk: K) util.DyadFn {
  const yk = comptime xk.container();
  const T = comptime K.backing(yk);
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const fill_val: T = @field(x, @tagName(xk));
      const src = @field(y, @tagName(yk)).slice();
      const res = N(T).init(vm.alloc, src.len) catch return V{ .err = .memory };
      const isNull = K.isNullFn(yk);
      for (src, res.slice()) |v, *d| d.* = if (isNull(v)) fill_val else v;
      return V.wrap(yk, res);
    }
  }.f;
}

fn fillPromote(comptime yk: K) util.DyadFn {
  const T = comptime K.backing(yk);
  const sk: K = comptime if (T == f32) .f else .i;
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const src = @field(y, @tagName(yk)).slice();
      const res = N(V).init(vm.alloc, src.len) catch return V{ .err = .memory };
      const isNull = K.isNullFn(yk);
      for (src, res.slice()) |v, *d| d.* = if (isNull(v)) x else V.wrap(sk, v);
      return .{ .L = res };
    }
  }.f;
}

fn fillList(vm: *VM, x: V, y: V) V {
  const ylen = y.len();
  const res = y.ref();
  for (0..ylen) |i| {
    const val = y.at(i);
    if (val.isNull()) {
      val.deinit(vm.alloc);
      res.L.slice()[i] = x;
    }
  }
  return res;
}

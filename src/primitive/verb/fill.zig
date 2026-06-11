const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

pub const Fill = struct {
  pub const op = .@"^";
  
  _b_B: VM.Dyad = fillVec(.b), // identity
  _i_I: VM.Dyad = fillVec(.i),
  _f_F: VM.Dyad = fillVec(.f),
  _s_S: VM.Dyad = fillVec(.s),
  _c_C: VM.Dyad = fillVec(.c),
  
  _i_F: VM.Dyad = fillPromote(.F),
  _f_I: VM.Dyad = fillPromote(.I),
  
  _b_L: VM.Dyad = fillList,
  _i_L: VM.Dyad = fillList,
  _f_L: VM.Dyad = fillList,
  _s_L: VM.Dyad = fillList,
  _c_L: VM.Dyad = fillList,
};

fn fillVec(comptime xk: K) VM.Dyad {
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

fn fillPromote(comptime yk: K) VM.Dyad {
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

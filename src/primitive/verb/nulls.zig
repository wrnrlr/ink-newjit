const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Nulls = struct {
  pub const op = .@"^";
  _b: util.MonadFn = nullsAtom(.b),
  _i: util.MonadFn = nullsAtom(.i),
  _f: util.MonadFn = nullsAtom(.f),
  _s: util.MonadFn = nullsAtom(.s),
  _c: util.MonadFn = nullsAtom(.c),
  _B: util.MonadFn = nullsVec(.B),
  _I: util.MonadFn = nullsVec(.I),
  _F: util.MonadFn = nullsVec(.F),
  _S: util.MonadFn = nullsVec(.S),
  _C: util.MonadFn = nullsVec(.C),
  _L: util.MonadFn = nullsListFn,
};

fn nullsAtom(comptime k: K) util.MonadFn {
  const isNull = k.isNullFn();
  return struct {
    fn f(_: *VM, x: V) V {
      const n = @field(x, @tagName(k));
      return .{ .b = isNull(n) };
    }
  }.f;
}

fn nullsVec(comptime k: K) util.MonadFn {
  const isNull = k.isNullFn();
  return struct {
    fn f(vm: *VM, x: V) V {
      const n = @field(x, @tagName(k));
      const res = N(bool).init(vm.alloc, n.ptr.len) catch return V{ .err = .memory };
      for (n.slice(), res.slice()) |v, *r| r.* = isNull(v);
      return .{ .B = res };
    }
  }.f;
}

fn nullsListFn(vm: *VM, x: V) V {
  const res = N(bool).init(vm.alloc, x.L.ptr.len) catch return V{ .err = .memory };
  for (x.L.slice(), res.slice()) |v, *r| r.* = v.isNull();
  return .{ .B = res };
}

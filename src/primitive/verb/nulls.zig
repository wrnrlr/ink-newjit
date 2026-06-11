const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

pub const Nulls = struct {
  pub const op = .@"^";
  _b: VM.MonadFn = nullsAtom(.b),
  _i: VM.MonadFn = nullsAtom(.i),
  _f: VM.MonadFn = nullsAtom(.f),
  _s: VM.MonadFn = nullsAtom(.s),
  _c: VM.MonadFn = nullsAtom(.c),
  _B: VM.MonadFn = nullsVec(.B),
  _I: VM.MonadFn = nullsVec(.I),
  _F: VM.MonadFn = nullsVec(.F),
  _S: VM.MonadFn = nullsVec(.S),
  _C: VM.MonadFn = nullsVec(.C),
  _L: VM.MonadFn = nullsListFn,
};

fn nullsAtom(comptime k: K) VM.MonadFn {
  const isNull = k.isNullFn();
  return struct {
    fn f(_: *VM, x: V) V {
      const n = @field(x, @tagName(k));
      return .{ .b = isNull(n) };
    }
  }.f;
}

fn nullsVec(comptime k: K) VM.MonadFn {
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

const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

pub const First = struct {
  pub const op = .@"*";
  _b: util.MonadFn = identity,
  _i: util.MonadFn = identity,
  _f: util.MonadFn = identity,
  _s: util.MonadFn = identity,
  _c: util.MonadFn = identity,
  _B: util.MonadFn = firstVec(.B),
  _I: util.MonadFn = firstVec(.I),
  _F: util.MonadFn = firstVec(.F),
  _S: util.MonadFn = firstVec(.S),
  _C: util.MonadFn = firstVec(.C),
  _L: util.MonadFn = firstFn,
  _m: util.MonadFn = firstFn,
  _M: util.MonadFn = firstFn,
};

pub const First_Name = struct {
  pub const op = .first;
  _b: util.MonadFn = identity,
  _i: util.MonadFn = identity,
  _f: util.MonadFn = identity,
  _s: util.MonadFn = identity,
  _c: util.MonadFn = identity,
  _B: util.MonadFn = firstVec(.B),
  _I: util.MonadFn = firstVec(.I),
  _F: util.MonadFn = firstVec(.F),
  _S: util.MonadFn = firstVec(.S),
  _C: util.MonadFn = firstVec(.C),
  _L: util.MonadFn = firstFn,
  _m: util.MonadFn = firstFn,
  _M: util.MonadFn = firstFn,
};

pub const Last_Name = struct {
  pub const op = .last;
  _b: util.MonadFn = identity,
  _i: util.MonadFn = identity,
  _f: util.MonadFn = identity,
  _s: util.MonadFn = identity,
  _c: util.MonadFn = identity,
  _B: util.MonadFn = lastVec(.B),
  _I: util.MonadFn = lastVec(.I),
  _F: util.MonadFn = lastVec(.F),
  _S: util.MonadFn = lastVec(.S),
  _C: util.MonadFn = lastVec(.C),
  _L: util.MonadFn = lastFn,
  _m: util.MonadFn = lastFn,
  _M: util.MonadFn = lastFn,
};


pub fn first(alloc: Alloc, x: V) V {
  if (x.len() == 0) return .blank;
  return switch (x) {
    inline .I, .F, .S, .C, .B => |n, yk| V.wrap(yk.atom(), n.slice()[0]),
    .L => |n| n.slice()[0].ref(),
    .m => |m| first(alloc, m.bv()),
    else => x.ref(),
  };
}

pub fn last(alloc: Alloc, x: V) V {
  const l = x.len();
  if (l == 0) return .blank;
  return switch (x) {
    inline .I, .F, .S, .C, .B => |n, yk| V.wrap(K.atom(yk), n.slice()[l - 1]),
    .L => |n| n.slice()[l - 1].ref(),
    .m => |m| last(alloc, m.bv()),
    else => x.ref(),
  };
}

fn identity(_: *VM, x: V) V { return x; }
fn firstFn(vm: *VM, x: V) V { return first(vm.alloc, x); }
fn lastFn(vm: *VM, x: V) V { return last(vm.alloc, x); }

fn firstVec(comptime yk: K) util.MonadFn {
  return struct {
    fn f(_: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      if (b.ptr.len == 0) return .blank;
      return V.wrap(comptime K.atom(yk), b.slice()[0]);
    }
  }.f;
}

fn lastVec(comptime yk: K) util.MonadFn {
  return struct {
    fn f(_: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      const n = b.ptr.len;
      if (n == 0) return .blank;
      return V.wrap(comptime K.atom(yk), b.slice()[n - 1]);
    }
  }.f;
}

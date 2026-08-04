const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op1 = @import("../../noun/operator.zig").Op1;
const h = @import("helper.zig");

const FirstImpl = struct {
  _b: VM.Monad = identity,
  _i: VM.Monad = identity,
  _f: VM.Monad = identity,
  _n: VM.Monad = identity,
  _d: VM.Monad = identity,
  _h: VM.Monad = identity,
  _s: VM.Monad = identity,
  _c: VM.Monad = identity,
  _B: VM.Monad = firstVec(.B),
  _I: VM.Monad = firstVec(.I),
  _F: VM.Monad = firstVec(.F),
  _N: VM.Monad = firstVec(.N),
  _D: VM.Monad = firstVec(.D),
  _H: VM.Monad = firstVec(.H),
  _S: VM.Monad = firstVec(.S),
  _C: VM.Monad = firstVec(.C),
  _L: VM.Monad = firstFn,
  _m: VM.Monad = firstFn,
  _M: VM.Monad = firstFn,
};

pub const First      = h._X(Op1, .@"*",  FirstImpl);
pub const First_Name = h._X(Op1, .first, FirstImpl);

pub const Last_Name = struct {
  pub const op = .last;
  _b: VM.Monad = identity,
  _i: VM.Monad = identity,
  _f: VM.Monad = identity,
  _n: VM.Monad = identity,
  _d: VM.Monad = identity,
  _h: VM.Monad = identity,
  _s: VM.Monad = identity,
  _c: VM.Monad = identity,
  _B: VM.Monad = lastVec(.B),
  _I: VM.Monad = lastVec(.I),
  _F: VM.Monad = lastVec(.F),
  _N: VM.Monad = lastVec(.N),
  _D: VM.Monad = lastVec(.D),
  _H: VM.Monad = lastVec(.H),
  _S: VM.Monad = lastVec(.S),
  _C: VM.Monad = lastVec(.C),
  _L: VM.Monad = lastFn,
  _m: VM.Monad = lastFn,
  _M: VM.Monad = lastFn,
};

pub fn first(alloc: Alloc, x: V) V {
  if (x.len() == 0) return .nil;
  return switch (x) {
    inline .I, .F, .S, .C, .B, .N, .D, .H => |n, yk| V.wrap(yk.atom(), n.slice()[0]),
    .L => |n| n.slice()[0].ref(),
    .m => |m| first(alloc, m.bv()),
    else => x.ref(),
  };
}

pub fn last(alloc: Alloc, x: V) V {
  const l = x.len();
  if (l == 0) return .nil;
  return switch (x) {
    inline .I, .F, .S, .C, .B, .N, .D, .H => |n, yk| V.wrap(K.atom(yk), n.slice()[l - 1]),
    .L => |n| n.slice()[l - 1].ref(),
    .m => |m| last(alloc, m.bv()),
    else => x.ref(),
  };
}

fn identity(_: *VM, x: V) V { return x; }
fn firstFn(vm: *VM, x: V) V { return first(vm.alloc, x); }
fn lastFn(vm: *VM, x: V) V { return last(vm.alloc, x); }

fn firstVec(comptime yk: K) VM.Monad {
  return struct {
    fn f(_: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      if (b.ptr.len == 0) return .nil;
      return V.wrap(comptime K.atom(yk), b.slice()[0]);
    }
  }.f;
}

fn lastVec(comptime yk: K) VM.Monad {
  return struct {
    fn f(_: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      const n = b.ptr.len;
      if (n == 0) return .nil;
      return V.wrap(comptime K.atom(yk), b.slice()[n - 1]);
    }
  }.f;
}

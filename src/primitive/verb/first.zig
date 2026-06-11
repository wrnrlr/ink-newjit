const std = @import("std");
const Alloc = std.mem.Allocator;
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op1 = @import("../../noun/operator.zig").Op1;
const h = @import("helper.zig");

const FirstImpl = struct {
  _b: VM.MonadFn = identity,
  _i: VM.MonadFn = identity,
  _f: VM.MonadFn = identity,
  _s: VM.MonadFn = identity,
  _c: VM.MonadFn = identity,
  _B: VM.MonadFn = firstVec(.B),
  _I: VM.MonadFn = firstVec(.I),
  _F: VM.MonadFn = firstVec(.F),
  _S: VM.MonadFn = firstVec(.S),
  _C: VM.MonadFn = firstVec(.C),
  _L: VM.MonadFn = firstFn,
  _m: VM.MonadFn = firstFn,
  _M: VM.MonadFn = firstFn,
};

pub const First      = h._X(Op1, .@"*",  FirstImpl);
pub const First_Name = h._X(Op1, .first, FirstImpl);

pub const Last_Name = struct {
  pub const op = .last;
  _b: VM.MonadFn = identity,
  _i: VM.MonadFn = identity,
  _f: VM.MonadFn = identity,
  _s: VM.MonadFn = identity,
  _c: VM.MonadFn = identity,
  _B: VM.MonadFn = lastVec(.B),
  _I: VM.MonadFn = lastVec(.I),
  _F: VM.MonadFn = lastVec(.F),
  _S: VM.MonadFn = lastVec(.S),
  _C: VM.MonadFn = lastVec(.C),
  _L: VM.MonadFn = lastFn,
  _m: VM.MonadFn = lastFn,
  _M: VM.MonadFn = lastFn,
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

fn firstVec(comptime yk: K) VM.MonadFn {
  return struct {
    fn f(_: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      if (b.ptr.len == 0) return .blank;
      return V.wrap(comptime K.atom(yk), b.slice()[0]);
    }
  }.f;
}

fn lastVec(comptime yk: K) VM.MonadFn {
  return struct {
    fn f(_: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      const n = b.ptr.len;
      if (n == 0) return .blank;
      return V.wrap(comptime K.atom(yk), b.slice()[n - 1]);
    }
  }.f;
}

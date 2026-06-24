const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

fn enlistListFn(vm: *VM, x: V) V { return enlistToL(vm.alloc, x); }

pub const Enlist = struct {
  pub const op = .@",";
  _b: VM.Monad = enlistAtom(.b),
  _i: VM.Monad = enlistAtom(.i),
  _f: VM.Monad = enlistAtom(.f),
  _s: VM.Monad = enlistAtom(.s),
  _c: VM.Monad = enlistAtom(.c),
  _B: VM.Monad = enlistListFn,
  _I: VM.Monad = enlistListFn,
  _F: VM.Monad = enlistListFn,
  _S: VM.Monad = enlistListFn,
  _C: VM.Monad = enlistListFn,
  _L: VM.Monad = enlistListFn,
  _m: VM.Monad = enlistListFn,
  _M: VM.Monad = enlistListFn,
  _o: VM.Monad = enlistListFn,
  _p: VM.Monad = enlistListFn,
  _x: VM.Monad = enlistListFn,
};

fn enlistAtom(comptime k: K) VM.Monad {
  const ck = comptime k.container();
  const T = comptime K.backing(ck);
  return struct {
    fn f(vm: *VM, x: V) V {
      const r = N(T).init(vm.alloc, 1) catch return V{ .err = .memory };
      r.slice()[0] = x.unwrap(k);
      return V.wrap(ck, r);
    }
  }.f;
}

fn enlistToL(alloc: Alloc, x: V) V {
  const res = N(V).init(alloc, 1) catch return V{ .err = .memory };
  res.slice()[0] = x.ref();
  return .{ .L = res };
}

/// Legacy helper used by flip.zig and pick.zig — always wraps in a generic list.
pub fn enlist(alloc: Alloc, x: V) V { return enlistToL(alloc, x); }

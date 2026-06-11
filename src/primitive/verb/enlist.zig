const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

fn enlistListFn(vm: *VM, x: V) V { return enlistToL(vm.alloc, x); }

pub const Enlist = struct {
  pub const op = .@",";
  _b: VM.MonadFn = enlistAtom(.b),
  _i: VM.MonadFn = enlistAtom(.i),
  _f: VM.MonadFn = enlistAtom(.f),
  _s: VM.MonadFn = enlistAtom(.s),
  _c: VM.MonadFn = enlistAtom(.c),
  _B: VM.MonadFn = enlistListFn,
  _I: VM.MonadFn = enlistListFn,
  _F: VM.MonadFn = enlistListFn,
  _S: VM.MonadFn = enlistListFn,
  _C: VM.MonadFn = enlistListFn,
  _L: VM.MonadFn = enlistListFn,
  _m: VM.MonadFn = enlistListFn,
  _M: VM.MonadFn = enlistListFn,
  _y: VM.MonadFn = enlistListFn,
  _p: VM.MonadFn = enlistListFn,
  _q: VM.MonadFn = enlistListFn,
  _v: VM.MonadFn = enlistListFn,
};

fn enlistAtom(comptime k: K) VM.MonadFn {
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

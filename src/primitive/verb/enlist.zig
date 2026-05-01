const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

fn enlistListFn(vm: *VM, x: V) V { return enlistToL(vm.alloc, x); }

pub const Enlist = struct {
  pub const op = .@",";
  _b: util.MonadFn = enlistAtom(.b),
  _i: util.MonadFn = enlistAtom(.i),
  _f: util.MonadFn = enlistAtom(.f),
  _s: util.MonadFn = enlistAtom(.s),
  _c: util.MonadFn = enlistAtom(.c),
  _B: util.MonadFn = enlistListFn,
  _I: util.MonadFn = enlistListFn,
  _F: util.MonadFn = enlistListFn,
  _S: util.MonadFn = enlistListFn,
  _C: util.MonadFn = enlistListFn,
  _L: util.MonadFn = enlistListFn,
  _m: util.MonadFn = enlistListFn,
  _M: util.MonadFn = enlistListFn,
  _y: util.MonadFn = enlistListFn,
  _p: util.MonadFn = enlistListFn,
  _q: util.MonadFn = enlistListFn,
  _v: util.MonadFn = enlistListFn,
};

fn enlistAtom(comptime k: K) util.MonadFn {
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

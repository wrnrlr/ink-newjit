const std = @import("std");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const Alloc = std.mem.Allocator;

pub const Tally = struct {
  pub const op = .@"#";

  _b: util.MonadFn = tallyAtom,
  _i: util.MonadFn = tallyAtom,
  _f: util.MonadFn = tallyAtom,
  _s: util.MonadFn = tallyAtom,
  _c: util.MonadFn = tallyAtom,
  _y: util.MonadFn = tallyAtom,
  _p: util.MonadFn = tallyAtom,
  _q: util.MonadFn = tallyAtom,
  _v: util.MonadFn = tallyAtom,
  _B: util.MonadFn = tally,
  _I: util.MonadFn = tally,
  _F: util.MonadFn = tally,
  _S: util.MonadFn = tally,
  _C: util.MonadFn = tally,
  _T: util.MonadFn = tally,
  _L: util.MonadFn = tally,
  _m: util.MonadFn = tally,
  _M: util.MonadFn = tally,
};

fn tallyAtom(_: *VM, _: V) V { return .{ .i = 1 }; }

fn tally(_: *VM, x: V) V {
  return .{ .i = @intCast(x.len()) };
}

pub const Count_Name = struct {
  pub const op = .count;
  _b: util.MonadFn = tallyAtom,
  _i: util.MonadFn = tallyAtom,
  _f: util.MonadFn = tallyAtom,
  _s: util.MonadFn = tallyAtom,
  _c: util.MonadFn = tallyAtom,
  _g: util.MonadFn = tallyAtom,
  _y: util.MonadFn = tallyAtom,
  _p: util.MonadFn = tallyAtom,
  _q: util.MonadFn = tallyAtom,
  _v: util.MonadFn = tallyAtom,
  _B: util.MonadFn = tally,
  _I: util.MonadFn = tally,
  _F: util.MonadFn = tally,
  _S: util.MonadFn = tally,
  _C: util.MonadFn = tally,
  _T: util.MonadFn = tally,
  _D: util.MonadFn = tally,
  _G: util.MonadFn = tally,
  _L: util.MonadFn = tally,
  _m: util.MonadFn = tally,
  _M: util.MonadFn = tally,
};

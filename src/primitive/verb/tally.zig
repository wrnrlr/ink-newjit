const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const h = @import("helper.zig");

fn tallyAtom(_: *VM, _: V) V { return .{ .i = 1 }; }
fn tally    (_: *VM, x: V) V { return .{ .i = @intCast(x.len()) }; }

const TallyImpl = struct {
  _b: util.MonadFn = tallyAtom,
  _i: util.MonadFn = tallyAtom,
  _f: util.MonadFn = tallyAtom,
  _s: util.MonadFn = tallyAtom,
  _c: util.MonadFn = tallyAtom,
  _func: util.MonadFn = tallyAtom,
  _partial: util.MonadFn = tallyAtom,
  _x: util.MonadFn = tallyAtom,
  _B: util.MonadFn = tally,
  _I: util.MonadFn = tally,
  _F: util.MonadFn = tally,
  _S: util.MonadFn = tally,
  _C: util.MonadFn = tally,
  _L: util.MonadFn = tally,
  _m: util.MonadFn = tally,
  _M: util.MonadFn = tally,
};

pub const Tally      = h._X(Op1, .@"#",  TallyImpl);
pub const Count_Name = h._X(Op1, .count, TallyImpl);

const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const h = @import("helper.zig");

fn tallyAtom(_: *VM, _: V) V { return .{ .i = 1 }; }
fn tally    (_: *VM, x: V) V { return .{ .i = @intCast(x.len()) }; }

const TallyImpl = struct {
  _b: VM.MonadFn = tallyAtom,
  _i: VM.MonadFn = tallyAtom,
  _f: VM.MonadFn = tallyAtom,
  _s: VM.MonadFn = tallyAtom,
  _c: VM.MonadFn = tallyAtom,
  _func: VM.MonadFn = tallyAtom,
  _partial: VM.MonadFn = tallyAtom,
  _x: VM.MonadFn = tallyAtom,
  _B: VM.MonadFn = tally,
  _I: VM.MonadFn = tally,
  _F: VM.MonadFn = tally,
  _S: VM.MonadFn = tally,
  _C: VM.MonadFn = tally,
  _L: VM.MonadFn = tally,
  _m: VM.MonadFn = tally,
  _M: VM.MonadFn = tally,
};

pub const Tally      = h._X(Op1, .@"#",  TallyImpl);
pub const Count_Name = h._X(Op1, .count, TallyImpl);

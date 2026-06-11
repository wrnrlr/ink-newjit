const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const h = @import("helper.zig");

fn tallyAtom(_: *VM, _: V) V { return .{ .i = 1 }; }
fn tally    (_: *VM, x: V) V { return .{ .i = @intCast(x.len()) }; }

const TallyImpl = struct {
  _b: VM.Monad = tallyAtom,
  _i: VM.Monad = tallyAtom,
  _f: VM.Monad = tallyAtom,
  _s: VM.Monad = tallyAtom,
  _c: VM.Monad = tallyAtom,
  _func: VM.Monad = tallyAtom,
  _partial: VM.Monad = tallyAtom,
  _x: VM.Monad = tallyAtom,
  _B: VM.Monad = tally,
  _I: VM.Monad = tally,
  _F: VM.Monad = tally,
  _S: VM.Monad = tally,
  _C: VM.Monad = tally,
  _L: VM.Monad = tally,
  _m: VM.Monad = tally,
  _M: VM.Monad = tally,
};

pub const Tally      = h._X(Op1, .@"#",  TallyImpl);
pub const Count_Name = h._X(Op1, .count, TallyImpl);

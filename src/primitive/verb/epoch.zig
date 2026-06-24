const std = @import("std");
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;

// epoch x — the version stamp of an array/dict/table (see rc.zig). Returns a
// fresh-at-allocation integer that is bumped whenever the value is mutated in
// place. Compare two snapshots for inequality to detect a change:
//   e0: epoch col   ...later...   $[e0 = epoch col; reuse; rebuild]
// Atoms have no header and are immutable, so `epoch` of a scalar is a type error.
pub const Epoch = struct {
  pub const op = .epoch;
  _B: VM.Monad = epochOf,
  _I: VM.Monad = epochOf,
  _F: VM.Monad = epochOf,
  _S: VM.Monad = epochOf,
  _C: VM.Monad = epochOf,
  _L: VM.Monad = epochOf,
  _m: VM.Monad = epochOf,
  _M: VM.Monad = epochOf,
};

fn epochOf(_: *VM, x: V) V {
  const e: u32 = switch (x) {
    inline .B, .I, .F, .S, .C, .L, .m, .M => |n| n.ptr.getEpoch(),
    else => return .{ .err = .@"type" },
  };
  return .{ .i = @bitCast(e) };
}

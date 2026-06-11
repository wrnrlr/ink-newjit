const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

/// I_Y: cut y into segments at the given indices.
pub const Cut = struct {
  _I_I: VM.Dyad = cutVec(.I),
  _I_F: VM.Dyad = cutVec(.F),
  _I_S: VM.Dyad = cutVec(.S),
  _I_C: VM.Dyad = cutVec(.C),
  _I_B: VM.Dyad = cutVec(.B),
  _I_L: VM.Dyad = cutList,
};

fn cutVec(comptime yk: K) VM.Dyad {
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const idxs = x.I.slice();
      const ylen = y.len();
      const n = @field(y, @tagName(yk));
      const res = N(V).init(vm.alloc, idxs.len) catch return V{ .err = .memory };
      const yend: i32 = @intCast(ylen);
      for (idxs, 0..) |start_i64, j| {
        const start: usize = @intCast(util.clamp(start_i64, 0, yend));
        const end_i64: i32 = if (j + 1 < idxs.len) idxs[j + 1] else yend;
        const end: usize = @intCast(util.clamp(end_i64, 0, yend));
        const seg_len = if (end > start) end - start else 0;
        if (seg_len == 0) {
          const empty = N(K.backing(yk)).init(vm.alloc, 0) catch return V{ .err = .memory };
          res.slice()[j] = @unionInit(V, @tagName(yk), empty);
          continue;
        }
        const out = N(K.backing(yk)).init(vm.alloc, seg_len) catch return V{ .err = .memory };
        @memcpy(out.slice(), n.slice()[start .. start + seg_len]);
        res.slice()[j] = @unionInit(V, @tagName(yk), out);
      }
      return .{ .L = res };
    }
  }.f;
}

fn cutList(vm: *VM, x: V, y: V) V {
  const idxs = x.I.slice();
  const ylen = y.len();
  const res = N(V).init(vm.alloc, idxs.len) catch return V{ .err = .memory };
  const yend: i32 = @intCast(ylen);
  for (idxs, 0..) |start_i64, j| {
    const start: usize = @intCast(util.clamp(start_i64, 0, yend));
    const end_i64: i32 = if (j + 1 < idxs.len) idxs[j + 1] else yend;
    const end: usize = @intCast(util.clamp(end_i64, 0, yend));
    const seg_len = if (end > start) end - start else 0;
    if (seg_len == 0) { res.slice()[j] = V.Values(vm.alloc, &.{}) catch return V{ .err = .memory }; continue; }
    const sub = N(V).init(vm.alloc, seg_len) catch return V{ .err = .memory };
    for (0..seg_len) |k| sub.slice()[k] = y.at(start + k);
    res.slice()[j] = promote(vm.alloc, sub);
  }
  return .{ .L = res };
}

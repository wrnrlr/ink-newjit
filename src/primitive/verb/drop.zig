const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

/// i_Y: drop n items from the front (n>0) or back (n<0) of a sequence.
pub const Drop = struct {
  pub const op = .@"_";
  _i_I: VM.Dyad = dropVec(.I),
  _i_F: VM.Dyad = dropVec(.F),
  _i_S: VM.Dyad = dropVec(.S),
  _i_C: VM.Dyad = dropVec(.C),
  _i_B: VM.Dyad = dropVec(.B),
  _i_L: VM.Dyad = dropList,
};

fn dropList(vm: *VM, x: V, y: V) V {
  const items = y.L.slice();
  const drop_count: usize = @intCast(@abs(x.i));
  const old_len = items.len;
  var start: usize = 0;
  var new_len: usize = 0;
  if (x.i > 0) {
    if (drop_count < old_len) { start = drop_count; new_len = old_len - drop_count; }
  } else if (x.i < 0) {
    if (drop_count < old_len) new_len = old_len - drop_count;
  } else {
    new_len = old_len;
  }
  const result = N(V).init(vm.alloc, new_len) catch return V{ .err = .memory };
  for (result.slice(), items[start .. start + new_len]) |*dst, src| dst.* = src.ref();
  return .{ .L = result };
}

fn dropVec(comptime yk: K) VM.Dyad {
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const b = @field(y, @tagName(yk));
      const drop_count: usize = @intCast(@abs(x.i));
      const old_len = b.ptr.len;
      var new_len: usize = 0;
      var start_offset: usize = 0;
      if (x.i > 0) {
        if (drop_count < old_len) { new_len = old_len - drop_count; start_offset = drop_count; }
      } else if (x.i < 0) {
        if (drop_count < old_len) new_len = old_len - drop_count;
      } else {
        new_len = old_len;
      }
      const result = N(K.backing(yk)).init(vm.alloc, new_len) catch return V{ .err = .memory };
      if (new_len > 0) @memcpy(result.slice(), b.slice()[start_offset .. start_offset + new_len]);
      return @unionInit(V, @tagName(yk), result);
    }
  }.f;
}

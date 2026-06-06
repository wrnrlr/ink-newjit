const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const r = @import("reduce.zig");

fn maxB(_: *VM, x: V) V {
  const s = x.B.slice();
  if (s.len == 0) return .blank;
  for (s) |v| if (v) return .{ .b = true };
  return .{ .b = false };
}

pub const Max = struct {
  pub const op = .@"|/";
  _B: util.MonadFn = maxB,
  _I: util.MonadFn = r.typedFold(i32, .@"|"),
  _F: util.MonadFn = r.typedFold(f32, .@"|"),
  _L: util.MonadFn = r.listFold(.@"|"),
};

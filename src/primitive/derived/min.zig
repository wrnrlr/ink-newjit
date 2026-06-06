const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const r = @import("reduce.zig");

fn minB(_: *VM, x: V) V {
  const s = x.B.slice();
  if (s.len == 0) return .blank;
  for (s) |v| if (!v) return .{ .b = false };
  return .{ .b = true };
}

pub const Min = struct {
  pub const op = .@"&/";
  _B: util.MonadFn = minB,
  _I: util.MonadFn = r.typedFold(i32, .@"&"),
  _F: util.MonadFn = r.typedFold(f32, .@"&"),
  _L: util.MonadFn = r.listFold(.@"&"),
};

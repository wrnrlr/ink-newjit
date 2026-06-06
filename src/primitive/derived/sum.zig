const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const r = @import("reduce.zig");

fn sumB(_: *VM, x: V) V {
  var acc: i32 = 0;
  for (x.B.slice()) |v| if (v) { acc += 1; };
  return .{ .i = acc };
}

pub const Sum = struct {
  pub const op = .@"+/";
  _B: util.MonadFn = sumB,
  _I: util.MonadFn = r.typedFold(i32, .@"+"),
  _F: util.MonadFn = r.typedFold(f32, .@"+"),
  _L: util.MonadFn = r.listFold(.@"+"),
};

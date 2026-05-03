const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const value = @import("../../noun/value.zig");
const V = value.V;

// ndo: apply f to init exactly n times
// 5(2*)/ 1 → 32
pub fn ndo(vm: *VM, base: V, n: i32, init: V, f: util.ApplyFn) V {
  if (n < 0) return .{ .err = .domain };
  var accum = init.ref();
  for (0..@intCast(n)) |_| {
    const args = [_]V{ accum };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

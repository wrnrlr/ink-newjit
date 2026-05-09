const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

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

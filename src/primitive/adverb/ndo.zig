const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// ndo: apply f to init exactly n times
// 5(2*)/ 1 → 32
//
// When base is a lambda we use the move-semantics call so the lambda body
// sees its argument with rc==1, enabling in-place mutation (concat append,
// arith mutation, etc.) on what's effectively the loop accumulator.
pub fn ndo(vm: *VM, base: V, n: i32, init: V, f: util.ApplyFn) V {
  if (n < 0) return .{ .err = .domain };
  var accum = init.ref();
  if (base.tag() == .o and base.o.isLambda()) {
    const ref = base.o;
    for (0..@intCast(n)) |_| {
      const args = [_]V{ accum };
      accum = vm.callLambdaAndRunMove(ref, &args);
    }
    return accum;
  }
  for (0..@intCast(n)) |_| {
    const args = [_]V{ accum };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

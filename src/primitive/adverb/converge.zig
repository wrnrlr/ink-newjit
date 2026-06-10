const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;

// converge: apply f until result matches previous (fixed point)
// f/x → apply f to x until f(r) = r
pub fn converge(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  const is_lambda = base.tag() == .o and base.o.isLambda();
  const lambda_ref = if (is_lambda) base.o else undefined;
  var prev = x.ref();
  while (true) {
    const args = [_]V{prev};
    const next = if (is_lambda) vm.callLambdaAndRun(lambda_ref, &args) else f(vm, base, &args);
    if (prev.eq(next)) {
      next.deinit(vm.alloc);
      return prev;
    }
    prev.deinit(vm.alloc);
    prev = next;
  }
}

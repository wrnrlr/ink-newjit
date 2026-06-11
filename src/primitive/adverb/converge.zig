const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;

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

// converges: collect all intermediate values until fixed point
// f\x → x, f(x), f(f(x)), ... until result repeats
pub fn converges(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  const is_lambda = base.tag() == .o and base.o.isLambda();
  const lambda_ref = if (is_lambda) base.o else undefined;
  var results: std.ArrayList(V) = .empty;
  defer results.deinit(vm.alloc);

  var prev = x.ref();
  results.append(vm.alloc, prev.ref()) catch {
    prev.deinit(vm.alloc);
    return V{ .err = .memory };
  };

  while (true) {
    const args = [_]V{prev};
    const next = if (is_lambda) vm.callLambdaAndRun(lambda_ref, &args) else f(vm, base, &args);
    if (prev.eq(next)) {
      next.deinit(vm.alloc);
      prev.deinit(vm.alloc);
      break;
    }
    prev.deinit(vm.alloc);
    prev = next;
    results.append(vm.alloc, prev.ref()) catch {
      for (results.items) |v| v.deinit(vm.alloc);
      prev.deinit(vm.alloc);
      return V{ .err = .memory };
    };
  }

  const out = N(V).init(vm.alloc, results.items.len) catch {
    for (results.items) |v| v.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  @memcpy(out.slice(), results.items);
  return promote(vm.alloc, out);
}

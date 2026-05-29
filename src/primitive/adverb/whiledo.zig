const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const Fn = @import("../../noun/operator.zig").Fn;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;

inline fn callOne(vm: *VM, func: V, arg: V, f: util.ApplyFn) V {
  if (func == .func and func.func.isLambda()) {
    const args = [_]V{arg};
    return vm.callLambdaAndRun(func.func, &args);
  }
  const args = [_]V{arg};
  return f(vm, func, &args);
}

// while: (cond)step/init — apply step while cond holds, return final value
//
// cond is called with a borrowed ref (we still own cur for the next iter);
// step receives cur via move semantics when it's a lambda, so the body sees
// rc==1 and can mutate the accumulator in place.
pub fn whiledo(vm: *VM, cond: V, step: V, init: V, f: util.ApplyFn) V {
  const step_is_lambda = step == .func and step.func.isLambda();
  var cur = init.ref();
  while (true) {
    const cond_result = callOne(vm, cond, cur, f);
    const keep = cond_result.isTrue();
    cond_result.deinit(vm.alloc);
    if (!keep) return cur;
    if (step_is_lambda) {
      const args = [_]V{cur};
      cur = vm.callLambdaAndRunMove(step.func, &args);
    } else {
      const next = callOne(vm, step, cur, f);
      cur.deinit(vm.alloc);
      cur = next;
    }
  }
}

// whilescan: (cond)step\init — collect values while cond(value) holds
// Semantics: include init if cond(init), apply step, repeat
pub fn whilescan(vm: *VM, cond: V, step: V, init: V, f: util.ApplyFn) V {
  var results: std.ArrayList(V) = .empty;
  defer results.deinit(vm.alloc);

  var cur = init.ref();
  while (true) {
    const cond_result = callOne(vm, cond, cur, f);
    const keep = cond_result.isTrue();
    cond_result.deinit(vm.alloc);
    if (!keep) {
      results.append(vm.alloc, cur) catch {
        for (results.items) |v| v.deinit(vm.alloc);
        cur.deinit(vm.alloc);
        return V{ .err = .memory };
      };
      break;
    }
    results.append(vm.alloc, cur) catch {
      for (results.items) |v| v.deinit(vm.alloc);
      cur.deinit(vm.alloc);
      return V{ .err = .memory };
    };
    cur = callOne(vm, step, cur, f);
  }

  const out = N(V).init(vm.alloc, results.items.len) catch {
    for (results.items) |v| v.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  @memcpy(out.slice(), results.items);
  return promote(vm.alloc, out);
}

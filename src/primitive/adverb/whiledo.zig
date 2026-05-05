const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const value = @import("../../noun/value.zig");
const V = value.V;
const N = value.N;

// while: (cond)step/init — apply step while cond holds, return final value
pub fn whiledo(vm: *VM, cond: V, step: V, init: V, f: util.ApplyFn) V {
  var cur = init.ref();
  while (true) {
    const cond_args = [_]V{cur};
    const cond_result = f(vm, cond, &cond_args);
    const keep = cond_result.isTrue();
    cond_result.deinit(vm.alloc);
    if (!keep) return cur;
    const step_args = [_]V{cur};
    const next = f(vm, step, &step_args);
    cur.deinit(vm.alloc);
    cur = next;
  }
}

// whilescan: (cond)step\init — collect values while cond(value) holds
// Semantics: include init if cond(init), apply step, repeat
pub fn whilescan(vm: *VM, cond: V, step: V, init: V, f: util.ApplyFn) V {
  var results: std.ArrayList(V) = .empty;
  defer results.deinit(vm.alloc);

  var cur = init.ref();
  while (true) {
    const cond_args = [_]V{cur};
    const cond_result = f(vm, cond, &cond_args);
    const keep = cond_result.isTrue();
    cond_result.deinit(vm.alloc);
    if (!keep) {
      cur.deinit(vm.alloc);
      break;
    }
    results.append(vm.alloc, cur.ref()) catch {
      for (results.items) |v| v.deinit(vm.alloc);
      cur.deinit(vm.alloc);
      return V{ .err = .memory };
    };
    const step_args = [_]V{cur};
    const next = f(vm, step, &step_args);
    cur.deinit(vm.alloc);
    cur = next;
  }

  const out = N(V).init(vm.alloc, results.items.len) catch {
    for (results.items) |v| v.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  @memcpy(out.slice(), results.items);
  return .{ .L = out };
}

const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const pick = @import("../verb/pick.zig");
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;
const emptyOf = @import("../promote.zig").emptyOf;

// Apply f to each element in x.
//
// The mapping types keep their shape: a dict maps over its VALUES and comes back
// keyed the same way (`+/'score@=player` stays keyed by player), and a table maps
// over its ROWS — which is also what `#t` counts, so the two agree.
pub fn each(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  return switch (x) {
    .m => eachDict(vm, base, x, f),
    .M => eachRows(vm, base, x, f),
    else => eachItems(vm, base, x, x.len(), f),
  };
}

fn eachDict(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  const keys = x.m.av();
  const vals = x.m.bv();
  // A scalar-key dict holds its lone value unwrapped: one call on the whole
  // value, not one per element of it.
  const mapped = if (keys.isAtom()) callOne(vm, base, f, vals.ref())
                 else eachItems(vm, base, vals, vals.len(), f);
  if (mapped.tag() == .err) return mapped;
  const d = Dict.init(vm.alloc, keys.ref(), mapped) catch {
    mapped.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// Rows, not columns: `x.at(i)` on a table reads its i'th COLUMN while `#x` counts
// rows, so iterating a table the generic way runs off the end of the column list.
fn eachRows(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  const n = x.len();
  const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (res.slice(), 0..) |*slot, i| {
    const row = pick.pickTableRowFn(vm, x, V{ .i = @intCast(i) });
    if (row.tag() == .err) {
      (V{ .L = res }).deinit(vm.alloc);
      return row;
    }
    slot.* = callOne(vm, base, f, row);
  }
  return promote(vm.alloc, res);
}

fn eachItems(vm: *VM, base: V, x: V, n: usize, f: util.ApplyFn) V {
  // Nothing to call, so nothing to infer a result type from: keep the source's.
  // Falling through would `promote` a zero-length buffer into an empty general
  // list, and `` `L `` is the one type most downstream primitives can't take.
  if (n == 0) return emptyOf(vm.alloc, x.tag());
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  const is_lambda = base.tag() == .o and base.o.isLambda();
  const lambda_ref = if (is_lambda) base.o else undefined;
  for (0..n) |i| {
    const item = x.at(i);
    const args = [_]V{item};
    res.slice()[i] = if (is_lambda) vm.callLambdaAndRun(lambda_ref, &args) else f(vm, base, &args);
    item.deinit(vm.alloc);
  }
  return promote(vm.alloc, res);
}

// One call, taking ownership of `item`.
fn callOne(vm: *VM, base: V, f: util.ApplyFn, item: V) V {
  defer item.deinit(vm.alloc);
  const args = [_]V{item};
  if (base.tag() == .o and base.o.isLambda()) return vm.callLambdaAndRun(base.o, &args);
  return f(vm, base, &args);
}

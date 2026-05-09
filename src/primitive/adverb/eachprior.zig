const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;
const util = @import("../../util.zig");

// eachPrior: apply f to each adjacent pair (f': in ngn/k)
// monadic: -':1 2 3 4 → first element unchanged, rest f(cur, prev)
// seeded: 10-':1 2 3 → f(1,10); f(2,1); f(3,2)
pub fn eachprior(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  const n = x.len();
  if (n == 0) return vm.aList() catch return V{ .err = .memory } ;

  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };

  if (init) |seed| {
    // seeded: apply f(x[0], seed), f(x[1], x[0]), ...
    var prev = seed.ref();
    defer prev.deinit(vm.alloc);
    for (0..n) |i| {
      const cur = x.at(i);
      defer cur.deinit(vm.alloc);
      const args = [_]V{ cur, prev };
      const next = f(vm, base, &args);
      prev.deinit(vm.alloc);
      prev = cur.ref();
      res.slice()[i] = next;
    }
  } else {
    // unseeded: first element passes through, rest get f(cur, prev)
    res.slice()[0] = x.at(0);
    for (1..n) |i| {
      const cur = x.at(i);
      defer cur.deinit(vm.alloc);
      const prev = x.at(i - 1);
      defer prev.deinit(vm.alloc);
      const args = [_]V{ cur, prev };
      res.slice()[i] = f(vm, base, &args);
    }
  }
  return promote(vm.alloc, res);
}

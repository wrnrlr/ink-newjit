const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

// Apply f to each element in x
pub fn each(vm: *VM, base: V, x: V, f: util.ApplyFn) V {
  const n = x.len();
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  const is_lambda = base.tag() == .func and base.func.isLambda();
  const lambda_ref = if (is_lambda) base.func else undefined;
  for (0..n) |i| {
    const item = x.at(i);
    const args = [_]V{item};
    res.slice()[i] = if (is_lambda) vm.callLambdaAndRun(lambda_ref, &args) else f(vm, base, &args);
    item.deinit(vm.alloc);
  }
  return promote(vm.alloc, res);
}

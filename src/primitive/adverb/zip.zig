const std = @import("std");
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

pub fn each2(vm: *VM, base: V, xs: []const V, f: util.ApplyFn) V {
  // Multi-arg each: zip all args together. Scalars (len=1) broadcast to match vector length.
  var n: usize = 1;
  for (xs) |x| {
    const xlen = x.len();
    if (xlen == 1) continue;
    if (n == 1) { n = xlen; }
    else if (n != xlen) return V{ .err = .length };
  }

  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };

  var call_args = vm.alloc.alloc(V, xs.len) catch {
    res.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  defer vm.alloc.free(call_args);

  for (0..n) |i| {
    for (xs, 0..) |x, j| call_args[j] = x.at(if (x.len() == 1) 0 else i);
    defer for (call_args) |a| a.deinit(vm.alloc);
    res.slice()[i] = f(vm, base, call_args);
  }
  return promote(vm.alloc, res);
}

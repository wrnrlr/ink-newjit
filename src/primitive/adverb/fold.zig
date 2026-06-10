const std = @import("std");
const util = @import("../../util.zig");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const opmod = @import("../../noun/operator.zig");
const Op1 = opmod.Op1;
const Op2 = opmod.Op2;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const dispatch = @import("../dispatch.zig");

// Map a base Op2 to its fused Op1 reducer (or null). Single source of truth
// shared with the optimizer's `+/x → Apply1 +/` peephole.
pub fn fusedReducerOf(op: Op2) ?Op1 {
  return switch (op) {
    .@"+" => .@"+/",
    .@"*" => .@"*/",
    .@"|" => .@"|/",
    .@"&" => .@"&/",
    else => null,
  };
}

pub fn fold(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  // No init + builtin dyad with a fused reducer + typed array → dispatch
  // straight to the monad table entry. Avoids the per-element fold loop.
  if (init == null and base.tag() == .o and base.o.kind == .callable
      and opmod.isOp2Idx(base.o.idx))
  {
    if (fusedReducerOf(base.o.getOp2())) |op1| {
      return dispatch.dispatch1(vm, op1, x);
    }
  }

  const n = x.len();

  var accum = if (init) |v| v.ref() else blk: {
    if (n == 0) return .blank;
    break :blk x.at(0);
  };

  const start: usize = if (init != null) 0 else 1;

  if (base.tag() == .o and base.o.isLambda()) {
    const ref = base.o;
    // Move semantics: transfer ownership of accum and item into the lambda's
    // locals. Inside the body, accum has rc==1 so in-place mutation kernels
    // (concat append, arith) can fire, turning what would be O(N²) loops into
    // O(N) amortised. The Return frame cleanup deinits the moved-in args.
    for (start..n) |i| {
      const item = x.at(i);
      const args = [_]V{ accum, item };
      accum = vm.callLambdaAndRunMove(ref, &args);
    }
    return accum;
  }

  for (start..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ accum, item };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
  }
  return accum;
}

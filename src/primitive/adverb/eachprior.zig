const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;
const util = @import("../../util.zig");
const Op2 = @import("../../noun/operator.zig").Op2;

// Typed fast path for `op':vec` on a homogeneous numeric vector: out[0]=v[0],
// out[i]=op(v[i], v[i-1]). Avoids per-element dispatch, V boxing, and promote.
// Handles the same-type arithmetic ops (+,-,*) on I and F — covers the common
// adjacent-difference idiom `-':`. Returns null for anything else.
fn eachpriorTyped(vm: *VM, op: Op2, x: V) ?V {
  switch (x.tag()) {
    inline .I, .F => |t| {
      const T = if (t == .I) i32 else f32;
      const s = @field(x, @tagName(t)).slice();
      const out = N(T).init(vm.alloc, s.len) catch return V{ .err = .memory };
      const o = out.slice();
      o[0] = s[0];
      const is_int = comptime t == .I;
      switch (op) {
        .@"-" => for (1..s.len) |i| { o[i] = if (is_int) s[i] -% s[i-1] else s[i] - s[i-1]; },
        .@"+" => for (1..s.len) |i| { o[i] = if (is_int) s[i] +% s[i-1] else s[i] + s[i-1]; },
        .@"*" => for (1..s.len) |i| { o[i] = if (is_int) s[i] *% s[i-1] else s[i] * s[i-1]; },
        else => { out.deinit(vm.alloc); return null; },
      }
      return V.wrap(t, out);
    },
    else => return null,
  }
}

// eachPrior: apply f to each adjacent pair (f': in ngn/k)
// monadic: -':1 2 3 4 → first element unchanged, rest f(cur, prev)
// seeded: 10-':1 2 3 → f(1,10); f(2,1); f(3,2)
pub fn eachprior(vm: *VM, base: V, init: ?V, x: V, f: util.ApplyFn) V {
  const n = x.len();
  if (n == 0) return vm.aList() catch return V{ .err = .memory } ;

  // Fast path: unseeded each-prior of a builtin arithmetic verb over a numeric
  // vector (e.g. `-':`). Falls through to the generic path otherwise.
  if (init == null and n > 0 and base.tag() == .func and base.func.isOp2()) {
    if (eachpriorTyped(vm, base.func.getOp2(), x)) |r| return r;
  }

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

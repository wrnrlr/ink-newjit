const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;

// ndos: collect init + n applications of f
// 5(2*)\ 1 → 1 2 4 8 16 32
pub fn ndos(vm: *VM, base: V, n: i32, init: V, f: util.ApplyFn) V {
  if (n < 0) return .{ .err = .domain };
  const count: usize = @intCast(n);
  var res = N(V).init(vm.alloc, count + 1) catch return V{ .err = .memory };
  var accum = init.ref();
  res.slice()[0] = accum.ref();
  for (0..count) |i| {
    const args = [_]V{ accum };
    const next = f(vm, base, &args);
    accum.deinit(vm.alloc);
    accum = next;
    res.slice()[i + 1] = accum.ref();
  }
  accum.deinit(vm.alloc);
  return promote(vm.alloc, res);
}

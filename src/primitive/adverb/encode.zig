const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// I\ — mixed-radix encode (number to digits)
// 24 60 60\3723 → 1 2 3   2\13 → 1 1 0 1
pub fn encode(vm: *VM, radix: V, n: V) V {
  const nv: i32 = switch (n) { .i => n.i, .b => if (n.b) 1 else 0, else => return V{ .err = .@"type" } };

  // Scalar radix: compute minimal representation in base rv
  if (radix == .i or radix == .b) {
    const rv: i32 = switch (radix) { .i => radix.i, .b => if (radix.b) 1 else 0, else => unreachable };
    if (rv <= 1) return V{ .err = .domain };
    if (nv == 0) return V{ .I = N(i32).n1(vm.alloc, &.{0}) catch return V{ .err = .memory } };
    // Count digits needed
    var count: usize = 0;
    var tmp = if (nv < 0) -nv else nv;
    while (tmp > 0) : (count += 1) tmp = @divTrunc(tmp, rv);
    var result = N(i32).init(vm.alloc, count) catch return V{ .err = .memory };
    tmp = if (nv < 0) -nv else nv;
    var j: usize = count;
    while (j > 0) {
      j -= 1;
      result.slice()[j] = @mod(tmp, rv);
      tmp = @divTrunc(tmp, rv);
    }
    return V{ .I = result };
  }

  const rlen = radix.len();
  var result = N(i32).init(vm.alloc, rlen) catch return V{ .err = .memory };
  var rem = nv;
  // Fill from right to left
  var i: usize = rlen;
  while (i > 0) {
    i -= 1;
    const r = radix.at(i); defer r.deinit(vm.alloc);
    const rv: i32 = switch (r) { .i => r.i, .b => if (r.b) 1 else 0, else => return V{ .err = .@"type" } };
    if (rv <= 0) { result.slice()[i] = rem; rem = 0; }
    else { result.slice()[i] = @mod(rem, rv); rem = @divTrunc(rem, rv); }
  }
  return V{ .I = result };
}

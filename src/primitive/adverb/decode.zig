const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;

// I/ — mixed-radix decode (digits to number)
// 24 60 60/1 2 3 → 3723   2/1 1 0 1 → 13
pub fn decode(vm: *VM, radix: V, digits: V) V {
  const m = digits.len();
  if (m == 0) return .{ .err = .domain };

  // Scalar radix: uniform base for all digits
  if (radix == .i or radix == .b) {
    const rv: i32 = switch (radix) { .i => radix.i, .b => if (radix.b) 1 else 0, else => unreachable };
    var acc: i32 = 0;
    for (0..m) |i| {
      const d = digits.at(i); defer d.deinit(vm.alloc);
      const dv: i32 = switch (d) {
        .i => d.i,
        .b => if (d.b) 1 else 0,
        else => return .{ .err = .@"type" }
      };
      acc = acc * rv + dv;
    }
    return .{ .i = acc };
  }

  const n = radix.len();
  if (n == 0) return V{ .err = .domain };
  // Use last n digits (or pad with zeros on left)
  var acc: i32 = 0;
  for (0..n) |i| {
    const r = radix.at(i); defer r.deinit(vm.alloc);
    const d_idx = if (m >= n) m - n + i else i;
    const d = if (d_idx < m) digits.at(d_idx) else V{ .i = 0 };
    defer d.deinit(vm.alloc);
    const rv: i32 = switch (r) { .i => r.i, .b => if (r.b) 1 else 0, else => return V{ .err = .@"type" } };
    const dv: i32 = switch (d) { .i => d.i, .b => if (d.b) 1 else 0, else => return V{ .err = .@"type" } };
    acc = acc * rv + dv;
  }
  return V{ .i = acc };
}

// pub const Decode = struct {
//   _I_i: VM.DyadFn,
//   _I_I: VM.DyadFn,
// };

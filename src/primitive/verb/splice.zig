const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const dispatch = @import("../dispatch.zig");

// ?[x;y;z] splice — replace the slice x[start..end] with z, where y is the
// two-element range [start;end] (or a single index i, meaning insert before i).
// Length-changing; reuses take/drop/concat so type promotion is consistent.
//   ?["abcd";1 3;"xyz"] -> "axyzd"
//   ?[1 2 3 4;1 1;99]    -> 1 99 2 3 4   (pure insert at index 1)
pub fn splice(vm: *VM, x: V, y: V, z: V) V {
  const xlen: i32 = @intCast(x.len());
  var start: i32 = undefined;
  var end: i32 = undefined;
  switch (y.tag()) {
    .i => { start = y.i; end = y.i; },
    .b => { start = @intFromBool(y.b); end = start; },
    .I => {
      const s = y.I.slice();
      if (s.len != 2) return V{ .err = .length };
      start = s[0]; end = s[1];
    },
    .B => {
      const s = y.B.slice();
      if (s.len != 2) return V{ .err = .length };
      start = @intFromBool(s[0]); end = @intFromBool(s[1]);
    },
    else => return V{ .err = .@"type" },
  }
  if (start < 0) start += xlen;
  if (end < 0) end += xlen;
  if (start < 0 or end > xlen or start > end) return V{ .err = .domain };

  // left = x[0..start]  (start # x)
  const left = dispatch.dispatch2(vm, .@"#", V{ .i = start }, x);
  if (left.tag() == .err) return left;
  defer left.deinit(vm.alloc);
  // right = x[end..]    (end _ x)
  const right = dispatch.dispatch2(vm, .@"_", V{ .i = end }, x);
  if (right.tag() == .err) return right;
  defer right.deinit(vm.alloc);
  // left , z , right
  const lz = dispatch.dispatch2(vm, .@",", left, z);
  if (lz.tag() == .err) return lz;
  defer lz.deinit(vm.alloc);
  return dispatch.dispatch2(vm, .@",", lz, right);
}

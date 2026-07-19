const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const h = @import("helper.zig");

// %x — Shape (monadic %; the dyad stays divide). The array-language shape verb
// (APL rho, J $): the rectangular extent of x as an int vector.
//
//   %5           →  !0        (atom: rank 0, empty shape)
//   %1 2 3       →  ,3
//   %(1 2;3 4;5 6) → 3 2      (list of equal-shape elements: prepend the count)
//   %(1 2;3 4 5) →  ,2        (ragged: stop at the first non-uniform level)
//   %"ab"        →  ,2
//
// k lists can be ragged, so shape descends only while every sibling agrees:
// the result is the maximal uniform prefix of the dimensions. Placed arrays
// (lib/gpu.k descriptors) carry the same vector in their `s field, recorded by
// gpu.hold via this verb — see doc/design/kk2.md §8.
pub const Shape = h.monadGroups(.@"%", .{
  .{ &[_]K{ .b, .i, .f, .s, .c, .d, .h }, shapeAtom },
  .{ &[_]K{ .B, .I, .F, .S, .C, .D, .H }, shapeVec },
  .{ &[_]K{.L}, shapeList },
});

fn wrapDims(vm: *VM, ds: []const i32) V {
  const out = N(i32).init(vm.alloc, ds.len) catch return V{ .err = .memory };
  @memcpy(out.slice(), ds);
  return .{ .I = out };
}

fn shapeAtom(vm: *VM, _: V) V {
  const out = N(i32).init(vm.alloc, 0) catch return V{ .err = .memory };
  return .{ .I = out };
}

fn shapeVec(vm: *VM, x: V) V {
  return wrapDims(vm, &.{@intCast(x.len())});
}

// Owned dimension vector of x (empty for atoms/non-arrays). For a list, descend
// only if every element's shape equals the first's — ragged levels stop here.
fn dims(vm: *VM, x: V, out: *std.ArrayList(i32)) !void {
  switch (x) {
    .B, .I, .F, .S, .C, .D, .H => try out.append(vm.alloc, @intCast(x.len())),
    .L => |n| {
      const items = n.slice();
      try out.append(vm.alloc, @intCast(items.len));
      if (items.len == 0) return;
      var head: std.ArrayList(i32) = .empty;
      defer head.deinit(vm.alloc);
      try dims(vm, items[0], &head);
      for (items[1..]) |e| {
        var s2: std.ArrayList(i32) = .empty;
        defer s2.deinit(vm.alloc);
        try dims(vm, e, &s2);
        if (!std.mem.eql(i32, head.items, s2.items)) return; // ragged: stop
      }
      try out.appendSlice(vm.alloc, head.items);
    },
    else => {},
  }
}

fn shapeList(vm: *VM, x: V) V {
  var out: std.ArrayList(i32) = .empty;
  defer out.deinit(vm.alloc);
  dims(vm, x, &out) catch return V{ .err = .memory };
  return wrapDims(vm, out.items);
}

const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const promote = @import("../promote.zig").promote;

/// X_i: delete the element at index i from x.
pub const Delete = struct {
  pub const op = .@"_";
  _I_i: VM.Dyad = deleteVec(.I),
  _F_i: VM.Dyad = deleteVec(.F),
  _S_i: VM.Dyad = deleteVec(.S),
  _C_i: VM.Dyad = deleteVec(.C),
  _B_i: VM.Dyad = deleteVec(.B),
  // Delete Dict & Table?
  _L_i: VM.Dyad = deleteList,
};

fn deleteVec(comptime xk: K) VM.Dyad {
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const n = @field(x, @tagName(xk));
      const i = toIdx(y.i, n.ptr.len) orelse return .{ .err = .length };
      return deleteTyped(xk, vm.alloc, n.slice(), i);
    }
  }.f;
}

fn deleteList(vm: *VM, x: V, y: V) V {
  const i = toIdx(y.i, x.L.ptr.len) orelse return .{ .err = .length };
  return deleteGeneric(vm.alloc, x, x.L.ptr.len, i);
}

inline fn toIdx(i: i32, len: usize) ?usize {
  if (i < 0 or @as(usize, @intCast(i)) >= len) return null;
  return @intCast(i);
}

/// Delete element at idx using two @memcpy calls (no per-element loop).
pub fn deleteTyped(comptime k: K, alloc: Alloc, data: []const K.backing(k), idx: usize) V {
  const res = N(K.backing(k)).init(alloc, data.len - 1) catch return V{ .err = .memory };
  @memcpy(res.slice()[0..idx], data[0..idx]);
  @memcpy(res.slice()[idx..], data[idx + 1 ..]);
  return @unionInit(V, @tagName(k), res);
}

/// Generic fallback for L and other types.
fn deleteGeneric(alloc: Alloc, x: V, n: usize, idx: usize) V {
  const len = n;
  const res = N(V).init(alloc, len - 1) catch return V{ .err = .memory };
  var j: usize = 0;
  for (0..len) |k| {
    if (k == idx) continue;
    res.slice()[j] = x.at(k);
    j += 1;
  }
  return promote(alloc, res);
}

const std = @import("std");
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

/// X_i: delete the element at index i from x.
pub const Delete = struct {
  pub const op = .@"_";
  _I_i: util.DyadFn = deleteVec(.I),
  _F_i: util.DyadFn = deleteVec(.F),
  _S_i: util.DyadFn = deleteVec(.S),
  _C_i: util.DyadFn = deleteVec(.C),
  _B_i: util.DyadFn = deleteVec(.B),
  // Delete Dict & Table?
  _L_i: util.DyadFn = deleteList,
};

fn deleteVec(comptime xk: K) util.DyadFn {
  return struct {
    fn f(vm: *VM, x: V, y: V) anyerror!V {
      const n = @field(x, @tagName(xk));
      const i = toIdx(y.i, n.ptr.len) orelse return .{ .err = .length };
      return deleteTyped(xk, vm.alloc, n.slice(), i);
    }
  }.f;
}

fn deleteList(vm: *VM, x: V, y: V) anyerror!V {
  const i = toIdx(y.i, x.L.ptr.len) orelse return .{ .err = .length };
  return deleteGeneric(vm.alloc, x, x.L.ptr.len, i);
}

inline fn toIdx(i: i32, len: usize) ?usize {
  if (i < 0 or @as(usize, @intCast(i)) >= len) return null;
  return @intCast(i);
}

/// Delete element at idx using two @memcpy calls (no per-element loop).
pub fn deleteTyped(comptime k: K, alloc: Alloc, data: []const K.backing(k), idx: usize) !V {
  const res = try N(K.backing(k)).init(alloc, data.len - 1);
  @memcpy(res.slice()[0..idx], data[0..idx]);
  @memcpy(res.slice()[idx..], data[idx + 1 ..]);
  return @unionInit(V, @tagName(k), res);
}

/// Generic fallback for L and other types.
fn deleteGeneric(alloc: Alloc, x: V, n: usize, idx: usize) !V {
  const len = n;
  const res = try N(V).init(alloc, len - 1);
  var j: usize = 0;
  for (0..len) |k| {
    if (k == idx) continue;
    res.slice()[j] = x.at(k);
    j += 1;
  }
  return promote(alloc, res);
}

const testing = std.testing;

fn makeN(alloc: Alloc, vals: []const i32) !N(i32) {
  const n = try N(i32).init(alloc, vals.len);
  @memcpy(n.slice(), vals);
  return n;
}
fn makeC(alloc: Alloc, s: []const u8) !N(u8) {
  const n = try N(u8).init(alloc, s.len);
  @memcpy(n.slice(), s);
  return n;
}

test "delete at start" {
  const alloc = testing.allocator;
  const data = try makeN(alloc, &.{ 1, 2, 3, 4 });
  defer data.deinit(alloc);
  const res = try deleteTyped(.I, alloc, data.slice(), 0);
  defer res.deinit(alloc);
  try testing.expectEqualSlices(i32, &.{ 2, 3, 4 }, res.I.slice());
}

test "delete at middle" {
  const alloc = testing.allocator;
  const data = try makeN(alloc, &.{ 1, 2, 3, 4 });
  defer data.deinit(alloc);
  const res = try deleteTyped(.I, alloc, data.slice(), 2);
  defer res.deinit(alloc);
  try testing.expectEqualSlices(i32, &.{ 1, 2, 4 }, res.I.slice());
}

test "delete at end" {
  const alloc = testing.allocator;
  const data = try makeN(alloc, &.{ 1, 2, 3, 4 });
  defer data.deinit(alloc);
  const res = try deleteTyped(.I, alloc, data.slice(), 3);
  defer res.deinit(alloc);
  try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, res.I.slice());
}

test "delete out of bounds" {
  const alloc = testing.allocator;
  const data = try makeN(alloc, &.{ 1, 2, 3 });
  defer data.deinit(alloc);
  try testing.expect(toIdx(5, data.ptr.len) == null);
}

test "delete char" {
  const alloc = testing.allocator;
  // "abcde" _ 2 -> "abde"
  const data = try makeC(alloc, "abcde");
  defer data.deinit(alloc);
  const res = try deleteTyped(.C, alloc, data.slice(), 2);
  defer res.deinit(alloc);
  try testing.expectEqualSlices(u8, "abde", res.C.slice());
}

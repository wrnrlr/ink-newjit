const std = @import("std");
const value = @import("../../noun/value.zig");
const promote = @import("../promote.zig");
const take = @import("./take.zig").take;
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = value.Dict;
const Table = value.Table;
const Alloc = std.mem.Allocator;

pub const UnionJoin = struct {
  pub const op = .@",";
  // Union join between two tables: append rows of y to x (requires same columns).
  _M_M: *VM.DyadFn = unionJoin,
};

pub const LeftJoin = struct {
  pub const op = .@",";
  // Left join table x with utable y: all rows of x, matched values from y by key.
  // pub fn _A_a(vm: *VM, x: V, y: V) V { return leftJoin(vm.alloc, x.A, y.a); }
};

// Union join: append all rows of t2 to t1. Returns t1 unchanged if columns differ.
fn unionJoin(alloc: Alloc, x: V, y: V) V {
  const t1 = x.M;
  const t2 = y.M;
  const cols1 = t1.av();
  const data1 = t1.bv();
  const cols2 = t2.av();
  const data2 = t2.bv();
  const ncols = cols1.len();
  if (ncols != cols2.len()) return .{ .A = try Table.init(alloc, cols1.ref(), data1.ref()) };
  for (0..ncols) |i| {
    if (!cols1.at(i).eq(cols2.at(i))) return .{ .A = try Table.init(alloc, cols1.ref(), data1.ref()) };
  }
  const new_data = N(V).init(alloc, ncols) catch return V{ .err = .memory };
  @memset(new_data.slice(), .blank);
  for (0..ncols) |ci| {
    const col1 = data1.at(ci);
    defer col1.deinit(alloc);
    const col2 = data2.at(ci);
    defer col2.deinit(alloc);
    new_data.slice()[ci] = try catCols(alloc, col1, col2);
  }
  return .{ .M = try Table.init(alloc, cols1.ref(), .{ .L = new_data }) };
}

// Concatenate two column vectors into one.
fn catCols(alloc: Alloc, col1: V, col2: V) V {
  const n1 = col1.len();
  const n2 = col2.len();
  const res = N(V).init(alloc, n1 + n2) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (0..n1) |i| res.slice()[i] = col1.at(i);
  for (0..n2) |i| res.slice()[n1 + i] = col2.at(i);
  return try promote.promote(alloc, res);
}

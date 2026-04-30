const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const Dict = @import("../../noun/value.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const enlist = @import("enlist.zig").enlist;
const promote = @import("../promote.zig").promote;

pub const Flip = struct {
  pub const op = .@"+";
  _I: util.MonadFn = flipVector,
  _F: util.MonadFn = flipVector,
  _B: util.MonadFn = flipVector,
  _m: util.MonadFn = flipDict,
  _M: util.MonadFn = flipTable,
  _L: util.MonadFn = flipList,
};

// 1D vector → list of single-element vectors, e.g. +1 2 3 → (,1;,2;,3)
fn flipVector(vm: *VM, x: V) !V {
  const n = x.len();
  const res = try N(V).init(vm.alloc, n);
  @memset(res.slice(), .blank);
  errdefer (V{ .L = res }).deinit(vm.alloc);
  for (res.slice(), 0..) |*r, i| {
    r.* = try enlist(vm.alloc, x.at(i)); // TODO why are we calling the generic enlist here we should know the type
  }
  return V{ .L = res };
}

// Dict → Table (values must be equal-length vectors)
fn flipDict(vm: *VM, x: V) !V {
  const alloc = vm.alloc;
  const keys = x.m.av();
  const vals = x.m.bv();
  if (keys.len() == 0) return x.ref();
  var row_count: ?usize = null;
  for (0..keys.len()) |i| {
    const col = if (keys.len() == 1 and !keys.tag().isVec()) vals.ref() else vals.at(i);
    defer col.deinit(alloc);
    if (!col.tag().isVec()) return V{ .err = .@"type" };
    if (row_count) |rc| {
      if (col.len() != rc) return V{ .err = .length };
    } else {
      row_count = col.len();
    }
  }
  var rk = keys.ref();
  var rv = vals.ref();
  if (keys.len() == 1 and !keys.tag().isVec()) {
    rk.deinit(alloc); rv.deinit(alloc);
    rk = try enlist(alloc, keys);
    rv = try enlist(alloc, vals);
  }
  return V{ .M = try Dict.init(alloc, rk, rv) };
}

// Table → Dict of columns
fn flipTable(vm: *VM, x: V) !V {
  return V{ .m = try Dict.init(vm.alloc, x.M.av().ref(), x.M.bv().ref()) };
}

// List of lists/dicts → transpose
fn flipList(vm: *VM, x: V) !V {
  return flipListAlloc(vm.alloc, x);
}

/// Public helper used by vm.zig and pick.zig — callers always pass .L.
pub fn flip(alloc: Alloc, x: V) !V {
  return flipListAlloc(alloc, x);
}

fn flipListAlloc(alloc: Alloc, x: V) !V {
  const slice = x.L.slice();
  if (slice.len == 0) return x.ref();
  if (slice[0].isDict()) {
    const keys = switch (slice[0]) {
      .m => |di| di.av(), .M => |di| di.av(), else => unreachable,
    };
    const num_cols = keys.len();
    const row_count = slice.len;
    const res_vals_n = try N(V).init(alloc, num_cols);
    for (0..num_cols) |j| {
      const col = try N(V).init(alloc, row_count);
      for (0..row_count) |i| {
        const item = slice[i];
        if (!item.isDict()) return V{ .err = .@"type" };
        const item_keys = switch (item) {
          .m => |di| di.av(), .M => |di| di.av(), else => unreachable,
        };
        if (!item_keys.eq(keys)) return V{ .err = .length };
        const item_vals = switch (item) {
          .m => |di| di.bv(), .M => |di| di.bv(), else => unreachable,
        };
        col.slice()[i] = if (num_cols == 1 and !keys.tag().isVec()) item_vals.ref() else item_vals.at(j);
      }
      res_vals_n.slice()[j] = try promote(alloc, col);
    }
    var rk = keys.ref();
    const rv = try promote(alloc, res_vals_n);
    if (num_cols == 1 and !keys.tag().isVec()) { rk.deinit(alloc); rk = try enlist(alloc, keys); }
    return V{ .M = try Dict.init(alloc, rk, rv) };
  }
  const row_count = slice.len;
  const first_row_len = slice[0].len();
  for (slice[1..]) |row| if (row.len() != first_row_len) return V{ .err = .length };
  const res = try N(V).init(alloc, first_row_len);
  for (0..first_row_len) |j| {
    const col = try N(V).init(alloc, row_count);
    for (0..row_count) |i| col.slice()[i] = slice[i].at(j);
    res.slice()[j] = try promote(alloc, col);
  }
  return try promote(alloc, res);
}

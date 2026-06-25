const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const enlist = @import("enlist.zig").enlist;
const promote = @import("../promote.zig").promote;
const promoteAs = @import("../promote.zig").promoteAs;

pub const Flip = struct {
  pub const op = .@"+";
// TODO flip scalar, k9 this is !rank
  _I: VM.Monad = flipVector,
  _F: VM.Monad = flipVector,
  _B: VM.Monad = flipVector,
  _m: VM.Monad = flipDict,
  _M: VM.Monad = flipTable,
  _L: VM.Monad = flipList,
};

// 1D vector → enlist, e.g. +1 2 3 → ,1 2 3
fn flipVector(vm: *VM, x: V) V {
  return enlist(vm.alloc, x);
}

// Enlist an ATOM to a 1-element TYPED vector (e.g. `n → ,`n as S), used for a
// single-column table's column-name vector so column access by symbol works.
fn enlistTyped(alloc: Alloc, x: V) V {
  const n = N(V).init(alloc, 1) catch return V{ .err = .memory };
  n.slice()[0] = x.ref();
  return promote(alloc, n);
}

// Dict → Table (values must be equal-length vectors)
fn flipDict(vm: *VM, x: V) V {
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
    // Column NAMES must be a typed vector (S for symbol keys), not a general list,
    // or table column-access (pickTableCol, which checks .S) silently misses.
    rk = enlistTyped(alloc, keys);
    rv = enlist(alloc, vals);
  }
  return V{ .M = Dict.init(alloc, rk, rv) catch return V{ .err = .memory } };
}

// Table → Dict of columns
fn flipTable(vm: *VM, x: V) V {
  const dict = Dict.init(vm.alloc, x.M.av().ref(), x.M.bv().ref()) catch return V{ .err = .memory };
  return V{ .m = dict };
}

// List of lists/dicts → transpose
fn flipList(vm: *VM, x: V) V {
  return flipListAlloc(vm.alloc, x);
}

/// Public helper used by vm.zig and pick.zig — callers always pass .L.
pub fn flip(alloc: Alloc, x: V) V {
  return flipListAlloc(alloc, x);
}

fn dictAv(v: V) V { return switch (v) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable }; }
fn dictBv(v: V) V { return switch (v) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable }; }

// Only promote when all elements share the same tag; otherwise keep as mixed list.
fn strictPromote(alloc: Alloc, n: N(V)) V {
  const s = n.slice();
  if (s.len == 0) return V{ .L = n };
  const k = s[0].tag();
  if (!k.isAtom()) return V{ .L = n };
  for (s[1..]) |v| if (v.tag() != k) return V{ .L = n };
  return promoteAs(alloc, n, k);
}

fn flipListAlloc(alloc: Alloc, x: V) V {
  const slice = x.L.slice();
  if (slice.len == 0) return x.ref();
  if (slice[0].isDict()) {
    const keys = dictAv(slice[0]);
    const num_cols = keys.len();
    const scalar_key = num_cols == 1 and !keys.tag().isVec();
    const row_count = slice.len;
    const res_vals_n = N(V).init(alloc, num_cols) catch return V{ .err = .memory };
    for (0..num_cols) |j| {
      const col = N(V).init(alloc, row_count) catch return V{ .err = .memory };
      for (0..row_count) |i| {
        const item = slice[i];
        if (!item.isDict()) return V{ .err = .@"type" };
        if (!dictAv(item).eq(keys)) return V{ .err = .length };
        const item_vals = dictBv(item);
        col.slice()[i] = if (scalar_key) item_vals.ref() else item_vals.at(j);
      }
      res_vals_n.slice()[j] = strictPromote(alloc, col);
    }
    var rk = keys.ref();
    const rv = promote(alloc, res_vals_n);
    if (scalar_key) { rk.deinit(alloc); rk = enlistTyped(alloc, keys); }
    return V{ .M = Dict.init(alloc, rk, rv) catch return V{ .err = .memory } };
  }
  const row_count = slice.len;
  const first_row_len = slice[0].len();
  for (slice[1..]) |row| if (row.len() != first_row_len) return V{ .err = .length };
  const res = N(V).init(alloc, first_row_len) catch return V{ .err = .memory };
  for (0..first_row_len) |j| {
    const col = N(V).init(alloc, row_count) catch return V{ .err = .memory };
    for (0..row_count) |i| col.slice()[i] = slice[i].at(j);
    res.slice()[j] = strictPromote(alloc, col);
  }
  return promote(alloc, res);
}

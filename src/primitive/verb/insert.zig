const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const pair = @import("pair.zig");
const util = @import("../../util.zig");
const take = @import("./take.zig").take;
const promote = @import("../promote.zig").promote;
const VM = @import("../../runtime/vm.zig").VM;
const N = @import("../../noun/value.zig").N;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;

pub const Insert = struct {
  pub const op = .@",";
  // t , dict — append dict as a new row to table t
  _M_m: util.DyadFn = insert,
};

pub const Upsert = struct {
  pub const op = .@",";
  // k , dict — upsert dict into keyed table k
  // pub fn _a_m(vm: *VM, x: V, y: V) V { return upsert(vm.alloc, x.a, y.m); }
};

fn insert(vm: *VM, t: V, d: V) V {
  const t_cols = t.M.av();
  const t_data = t.M.bv();
  const ncols = t_cols.len();
  const new_data = N(V).init(vm.alloc, ncols) catch return V{ .err = .memory };
  @memset(new_data.slice(), .blank);
  for (0..ncols) |ci| {
    const col_name = t_cols.at(ci);
    const col = t_data.at(ci);
    defer col.deinit(vm.alloc);
    const dv = findDictVal(d.m, col_name) orelse return .{ .err = .length };
    defer dv.deinit(vm.alloc);
    new_data.slice()[ci] = appendToCol(vm.alloc, col, dv);
  }
  return .{ .M = Dict.init(vm.alloc, t_cols.ref(), .{ .L = new_data }) catch return V{ .err = .memory } };
}

// Return value in dict d for key matching col_name, or null if not found.
// Returns a retained reference (caller must deinit).
fn findDictVal(d: Dict, col_name: V) ?V {
  const keys = d.av();
  const vals = d.bv();
  for (0..keys.len()) |i| {
    if (keys.at(i).eq(col_name)) return vals.at(i);
  }
  return null;
}

// Append atom `val` to vector/list `col`; return a new promoted vector.
fn appendToCol(alloc: Alloc, col: V, val: V) V {
  const n = col.len();
  const res = N(V).init(alloc, n + 1) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (0..n) |i| res.slice()[i] = col.at(i);
  res.slice()[n] = val.ref();
  return promote(alloc, res);
}

// Replace element at row index `ri` in vector/list `col`; return a new promoted vector.
fn replaceInCol(alloc: Alloc, col: V, ri: usize, val: V) V {
  const n = col.len();
  const res = N(V).init(alloc, n) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (0..n) |i| res.slice()[i] = if (i == ri) val.ref() else col.at(i);
  return promote(alloc, res);
}

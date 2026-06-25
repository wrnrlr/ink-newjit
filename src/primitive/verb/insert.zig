const std = @import("std");
const promote = @import("../promote.zig").promote;
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const Alloc = std.mem.Allocator;

pub const Insert = struct {
  pub const op = .@",";
  // t , dict — append dict as a new row to table t
  _M_m: VM.Dyad = insert,
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
    const dv = findDictVal(d.m, col_name) orelse {
      // Shape mismatch: free the rows already built (slots [0,ci)) plus the
      // remaining .blank slots and the N(V) shell, so the partial result
      // doesn't leak. (col itself is freed by the defer above.)
      new_data.deinit(vm.alloc);
      return .{ .err = .length };
    };
    defer dv.deinit(vm.alloc);
    new_data.slice()[ci] = appendToCol(vm.alloc, col, dv);
  }
  return .{ .M = Dict.init(vm.alloc, t_cols.ref(), .{ .L = new_data }) catch return V{ .err = .memory } };
}

// u , dict — upsert a row dict into a keyed table (utable). The dict must carry the
// key column's value; if a row with that key exists its value columns are replaced,
// otherwise a new row is appended. Single key column only (returns !rank otherwise).
pub fn upsert(vm: *VM, u: V, d: V) V {
  const alloc = vm.alloc;
  const key_tbl = u.m.av();                       // M: key columns
  const val_tbl = u.m.bv();                       // M: value columns
  const key_names = key_tbl.M.av();
  const key_data = key_tbl.M.bv();
  const val_names = val_tbl.M.av();
  const val_data = val_tbl.M.bv();
  if (key_names.len() != 1) return V{ .err = .rank };
  const key_name = key_names.at(0);
  defer key_name.deinit(alloc);
  const key_val = findDictVal(d.m, key_name) orelse return V{ .err = .length };
  defer key_val.deinit(alloc);
  const key_col = key_data.at(0);
  defer key_col.deinit(alloc);

  // locate an existing row with this key
  var found: ?usize = null;
  for (0..key_col.len()) |r| {
    const cell = key_col.at(r);
    defer cell.deinit(alloc);
    if (cell.eq(key_val)) { found = r; break; }
  }

  // rebuild the value columns (replace at row, or append a new row)
  const nval = val_names.len();
  const new_val_data = N(V).init(alloc, nval) catch return V{ .err = .memory };
  @memset(new_val_data.slice(), .blank);
  for (0..nval) |ci| {
    const cn = val_names.at(ci);
    defer cn.deinit(alloc);
    const col = val_data.at(ci);
    defer col.deinit(alloc);
    const dv = findDictVal(d.m, cn);
    defer if (dv) |v| v.deinit(alloc);
    if (found) |row| {
      new_val_data.slice()[ci] = if (dv) |v| replaceInCol(alloc, col, row, v) else col.ref();
    } else if (dv) |v| {
      new_val_data.slice()[ci] = appendToCol(alloc, col, v);
    } else {
      new_val_data.deinit(alloc);
      return .{ .err = .length };
    }
  }
  const new_val_tbl = V{ .M = Dict.init(alloc, val_names.ref(), .{ .L = new_val_data }) catch return V{ .err = .memory } };

  // key table is unchanged on replace; on insert the key column gains a row
  const new_key_tbl = if (found != null) key_tbl.ref() else blk: {
    const nk = N(V).init(alloc, 1) catch return V{ .err = .memory };
    nk.slice()[0] = appendToCol(alloc, key_col, key_val);
    break :blk V{ .M = Dict.init(alloc, key_names.ref(), .{ .L = nk }) catch return V{ .err = .memory } };
  };
  return .{ .m = Dict.init(alloc, new_key_tbl, new_val_tbl) catch return V{ .err = .memory } };
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

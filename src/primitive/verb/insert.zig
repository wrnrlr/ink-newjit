const std = @import("std");
const promote = @import("../promote.zig").promote;
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const K = @import("../../noun/class.zig").K;
const Alloc = std.mem.Allocator;

pub const Insert = struct {
  pub const op = .@",";
  // t , m — append a dict row (plain dict) OR left-join (when m is a keyed table)
  _M_m: VM.Dyad = insertOrLeftjoin,
};

// t , m: a keyed table (m with M keys) on the right is a LEFT JOIN; a plain dict is a row append.
fn insertOrLeftjoin(vm: *VM, t: V, d: V) V {
  if (d.m.av().tag() == .M) return leftjoin(vm, t, d);
  return insert(vm, t, d);
}

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
    const cv = colAppend(vm.alloc, col, dv);
    if (cv.tag() == .err) { new_data.deinit(vm.alloc); return cv; }  // type mismatch → propagate
    new_data.slice()[ci] = cv;
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
    const cv = if (found) |row|
      (if (dv) |v| colReplace(alloc, col, row, v) else col.ref())
    else if (dv) |v| colAppend(alloc, col, v) else {
      new_val_data.deinit(alloc);
      return .{ .err = .length };
    };
    if (cv.tag() == .err) { new_val_data.deinit(alloc); return cv; }  // type mismatch → propagate
    new_val_data.slice()[ci] = cv;
  }
  const new_val_tbl = V{ .M = Dict.init(alloc, val_names.ref(), .{ .L = new_val_data }) catch return V{ .err = .memory } };

  // key table is unchanged on replace; on insert the key column gains a row
  const new_key_tbl = if (found != null) key_tbl.ref() else blk: {
    const nk = N(V).init(alloc, 1) catch return V{ .err = .memory };
    nk.slice()[0] = colAppend(alloc, key_col, key_val);
    break :blk V{ .M = Dict.init(alloc, key_names.ref(), .{ .L = nk }) catch return V{ .err = .memory } };
  };
  return .{ .m = Dict.init(alloc, new_key_tbl, new_val_tbl) catch return V{ .err = .memory } };
}

// t , k — LEFT JOIN a table t with a keyed table (utable) k. Every row of t is kept;
// for each row the key column's value is looked up in k. k's value columns are merged in:
// a column shared with t is overridden by k's value where the key matched (else t's value
// stays); a k-only column gets k's value where matched, else the column-type's zero (so the
// result column stays typed). This IS the ECS dense+sparse join (cf. ssetAlign).
pub fn leftjoin(vm: *VM, t: V, k: V) V {
  const alloc = vm.alloc;
  const t_names = t.M.av();              // S: t column names
  const t_data = t.M.bv();               // L: t columns
  const kkey_names = k.m.av().M.av();    // S: key column names
  const kkey_data = k.m.av().M.bv();     // L: key columns
  const kval_names = k.m.bv().M.av();    // S: value column names
  const kval_data = k.m.bv().M.bv();     // L: value columns
  if (kkey_names.len() != 1) return V{ .err = .rank };
  const keyname = kkey_names.at(0);
  const kkeycol = kkey_data.at(0);
  defer kkeycol.deinit(alloc);

  const tkpos = symPos(t_names, keyname) orelse return V{ .err = .length };
  const tkeycol = t_data.at(tkpos);
  defer tkeycol.deinit(alloc);
  const nrows = tkeycol.len();

  // per t-row matched k-row index, or -1
  const kidx = alloc.alloc(i64, nrows) catch return V{ .err = .memory };
  defer alloc.free(kidx);
  for (0..nrows) |i| {
    const cell = tkeycol.at(i); defer cell.deinit(alloc);
    kidx[i] = findInCol(alloc, kkeycol, cell);
  }

  // result = all t columns (shared ones overridden) ++ k-only value columns
  var n_konly: usize = 0;
  for (0..kval_names.len()) |j| {
    const cn = kval_names.at(j);
    if (symPos(t_names, cn) == null) n_konly += 1;
  }
  const ncols = t_names.len() + n_konly;
  const res_names = N(V).init(alloc, ncols) catch return V{ .err = .memory };
  const res_cols = N(V).init(alloc, ncols) catch return V{ .err = .memory };

  for (0..t_names.len()) |j| {
    const cn = t_names.at(j);
    res_names.slice()[j] = cn.ref();
    const tcol = t_data.at(j); defer tcol.deinit(alloc);
    if (symPos(kval_names, cn)) |kp| {
      const kcol = kval_data.at(kp); defer kcol.deinit(alloc);
      res_cols.slice()[j] = colBlend(alloc, tcol, kcol, kidx);
    } else res_cols.slice()[j] = tcol.ref();
  }
  var oi = t_names.len();
  for (0..kval_names.len()) |j| {
    const cn = kval_names.at(j);
    if (symPos(t_names, cn) != null) continue;
    res_names.slice()[oi] = cn.ref();
    const kcol = kval_data.at(j); defer kcol.deinit(alloc);
    res_cols.slice()[oi] = colGather(alloc, kcol, kidx);
    oi += 1;
  }
  return .{ .M = Dict.init(alloc, promote(alloc, res_names), .{ .L = res_cols }) catch return V{ .err = .memory } };
}

// k1 , k2 — OUTER JOIN two keyed tables: k1 with every row of k2 upserted (k2 wins on
// shared keys, k1-only and k2-only keys both kept). Merge two keyed archetypes/worlds.
pub fn outerjoin(vm: *VM, k1: V, k2: V) V {
  const alloc = vm.alloc;
  const k2_key_names = k2.m.av().M.av();
  const k2_key_data = k2.m.av().M.bv();
  const k2_val_names = k2.m.bv().M.av();
  const k2_val_data = k2.m.bv().M.bv();
  const nkey = k2_key_names.len();
  const nval = k2_val_names.len();
  const ncol = nkey + nval;
  const kcol0 = k2_key_data.at(0); const nrows = kcol0.len(); kcol0.deinit(alloc);

  var acc = k1.ref();
  for (0..nrows) |r| {
    // build the row dict {keycols…, valcols…} at row r
    const rn = N(V).init(alloc, ncol) catch return V{ .err = .memory };
    const rv = N(V).init(alloc, ncol) catch return V{ .err = .memory };
    for (0..nkey) |j| { rn.slice()[j] = k2_key_names.at(j).ref(); const c = k2_key_data.at(j); defer c.deinit(alloc); rv.slice()[j] = c.at(r); }
    for (0..nval) |j| { rn.slice()[nkey + j] = k2_val_names.at(j).ref(); const c = k2_val_data.at(j); defer c.deinit(alloc); rv.slice()[nkey + j] = c.at(r); }
    const row = V{ .m = Dict.init(alloc, promote(alloc, rn), .{ .L = rv }) catch return V{ .err = .memory } };
    defer row.deinit(alloc);
    const next = upsert(vm, acc, row);
    acc.deinit(alloc);
    acc = next;
  }
  return acc;
}

fn symPos(names: V, sym: V) ?usize {
  for (0..names.len()) |i| {
    const k = names.at(i);
    if (k.eq(sym)) return i;
  }
  return null;
}

fn findInCol(alloc: Alloc, col: V, key: V) i64 {
  for (0..col.len()) |r| {
    const cell = col.at(r); defer cell.deinit(alloc);
    if (cell.eq(key)) return @intCast(r);
  }
  return -1;
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

// ── type-stable column ops ───────────────────────────────────────────────────────
// A table column is a TYPED vector. These keep its type and copy the backing store
// directly (a @memcpy, no per-element V boxing or type re-inference — fast). A value of
// the wrong type is a DOMAIN error (!type), never a silent re-type to a general list.

// Append `val to typed column `col → a new column of the same type. Mismatch → !type.
fn colAppend(alloc: Alloc, col: V, val: V) V {
  switch (col) {
    inline .B, .I, .F, .S, .C => |n, k| {
      if (val.tag() != comptime k.atom()) return V{ .err = .@"type" };
      const r = N(K.backing(k)).init(alloc, n.ptr.len + 1) catch return V{ .err = .memory };
      @memcpy(r.slice()[0..n.ptr.len], n.slice());
      r.slice()[n.ptr.len] = val.unwrap(comptime k.atom());
      return V.wrap(k, r);
    },
    .L => |n| {
      const r = N(V).init(alloc, n.ptr.len + 1) catch return V{ .err = .memory };
      for (n.slice(), 0..) |e, i| r.slice()[i] = e.ref();
      r.slice()[n.ptr.len] = val.ref();
      return V{ .L = r };
    },
    else => return V{ .err = .@"type" },
  }
}

// Replace row `ri of typed column `col with `val (same type). Mismatch → !type.
fn colReplace(alloc: Alloc, col: V, ri: usize, val: V) V {
  switch (col) {
    inline .B, .I, .F, .S, .C => |n, k| {
      if (val.tag() != comptime k.atom()) return V{ .err = .@"type" };
      const r = N(K.backing(k)).init(alloc, n.ptr.len) catch return V{ .err = .memory };
      @memcpy(r.slice(), n.slice());
      r.slice()[ri] = val.unwrap(comptime k.atom());
      return V.wrap(k, r);
    },
    .L => |n| {
      const r = N(V).init(alloc, n.ptr.len) catch return V{ .err = .memory };
      for (n.slice(), 0..) |e, i| r.slice()[i] = if (i == ri) val.ref() else e.ref();
      return V{ .L = r };
    },
    else => return V{ .err = .@"type" },
  }
}

// per row: matched → kcol[idx], else tcol[i]. tcol and kcol must share type (else !type).
fn colBlend(alloc: Alloc, tcol: V, kcol: V, kidx: []const i64) V {
  switch (tcol) {
    inline .B, .I, .F, .S, .C => |tn, k| {
      if (kcol.tag() != k) return V{ .err = .@"type" };
      const kn = kcol.unwrap(k);
      const r = N(K.backing(k)).init(alloc, kidx.len) catch return V{ .err = .memory };
      for (kidx, 0..) |ix, i| r.slice()[i] = if (ix >= 0) kn.slice()[@intCast(ix)] else tn.slice()[i];
      return V.wrap(k, r);
    },
    .L => |tn| {
      const r = N(V).init(alloc, kidx.len) catch return V{ .err = .memory };
      for (kidx, 0..) |ix, i| r.slice()[i] = if (ix >= 0) kcol.at(@intCast(ix)) else tn.slice()[i].ref();
      return V{ .L = r };
    },
    else => return V{ .err = .@"type" },
  }
}

// per row: matched → kcol[idx], else the column type's zero. Result keeps kcol's type.
fn colGather(alloc: Alloc, kcol: V, kidx: []const i64) V {
  switch (kcol) {
    inline .B, .I, .F, .S, .C => |n, k| {
      const T = K.backing(k);
      const r = N(T).init(alloc, kidx.len) catch return V{ .err = .memory };
      const z: T = comptime if (T == bool) false else 0;
      for (kidx, 0..) |ix, i| r.slice()[i] = if (ix >= 0) n.slice()[@intCast(ix)] else z;
      return V.wrap(k, r);
    },
    .L => |n| {
      const r = N(V).init(alloc, kidx.len) catch return V{ .err = .memory };
      for (kidx, 0..) |ix, i| r.slice()[i] = if (ix >= 0) n.slice()[@intCast(ix)].ref() else V.blank;
      return V{ .L = r };
    },
    else => return V{ .err = .@"type" },
  }
}

const std = @import("std");
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const promote = @import("../promote.zig");
const take = @import("./take.zig").take;
const VM = @import("../../runtime/vm.zig").VM;
const N = @import("../../noun/value.zig").N;
const V = value.V;
const Dict = value.Dict;
const Table = value.Table;
const Alloc = std.mem.Allocator;

pub const UnionJoin = struct {
  pub const op = .@",";
  // Union join between two tables: append rows of y to x (requires same columns).
  _M_M: *util.DyadFn = unionJoin,
};

pub const LeftJoin = struct {
  pub const op = .@",";
  // Left join table x with utable y: all rows of x, matched values from y by key.
  // pub fn _A_a(vm: *VM, x: V, y: V) V { return leftJoin(vm.alloc, x.A, y.a); }
};

// pub const OuterJoin = struct {
//   pub const op = .@",";
//   // Outer join utable x and y: x rows updated/extended by y rows.
//   pub fn _a_a(vm: *VM, x: V, y: V) V { return outerJoin(vm.alloc, x.a, y.a); }
// };

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

// Left join: all rows of t, with value columns from k matched by key. Unmatched rows get 0.
// fn leftJoin(alloc: Alloc, t: Table, k: UTable) V {
//   const t_cols = t.av();
//   const t_data = t.bv();
//   const kt = k.av().A;
//   const vt = k.bv().A;
//   const kc = kt.av();
//   const kd = kt.bv();
//   const vc = vt.av();
//   const vd = vt.bv();
//   const nrows = (V{ .M = t }).len();
//   const nkcols = kc.len();
//   const nvcols = vc.len();
//   const ntcols = t_cols.len();
//   const krows = (V{ .M = kt }).len();

//   // Map each key column to its index in t_cols.
//   const key_col_map = alloc.alloc(?usize, nkcols) catch return V{ .err = .memory };
//   defer alloc.free(key_col_map);
//   for (0..nkcols) |ki| {
//     key_col_map[ki] = null;
//     for (0..ntcols) |ti| {
//       if (t_cols.at(ti).eq(kc.at(ki))) { key_col_map[ki] = ti; break; }
//     }
//   }

//   // For each t row, find the matching row index in k (or null).
//   const match_rows = alloc.alloc(?usize, nrows) catch return V{ .err = .memory };
//   defer alloc.free(match_rows);
//   @memset(match_rows, null);
//   for (0..nrows) |ri| {
//     outer: for (0..krows) |ki| {
//       for (0..nkcols) |ci| {
//         const tci = key_col_map[ci] orelse continue :outer;
//         const tcol = t_data.at(tci);
//         defer tcol.deinit(alloc);
//         const kcol = kd.at(ci);
//         defer kcol.deinit(alloc);
//         if (!tcol.at(ri).eq(kcol.at(ki))) continue :outer;
//       }
//       match_rows[ri] = ki;
//       break;
//     }
//   }

//   // Count extra value cols from k not already in t.
//   var nextra: usize = 0;
//   for (0..nvcols) |vi| {
//     var found = false;
//     for (0..ntcols) |ti| { if (t_cols.at(ti).eq(vc.at(vi))) { found = true; break; } }
//     if (!found) nextra += 1;
//   }
//   const extra_vi = alloc.alloc(usize, nextra) catch return V{ .err = .memory };
//   defer alloc.free(extra_vi);
//   var ecount: usize = 0;
//   for (0..nvcols) |vi| {
//     var found = false;
//     for (0..ntcols) |ti| { if (t_cols.at(ti).eq(vc.at(vi))) { found = true; break; } }
//     if (!found) { extra_vi[ecount] = vi; ecount += 1; }
//   }

//   const out_ncols = ntcols + nextra;
//   const out_data = N(V).init(alloc, out_ncols) catch return V{ .err = .memory };
//   @memset(out_data.slice(), .blank);

//   // Build t columns, overriding from k's value cols where key matches.
//   for (0..ntcols) |ti| {
//     var vcol_idx: ?usize = null;
//     for (0..nvcols) |vi| { if (t_cols.at(ti).eq(vc.at(vi))) { vcol_idx = vi; break; } }
//     if (vcol_idx) |vi| {
//       const t_col = t_data.at(ti);
//       defer t_col.deinit(alloc);
//       const v_col = vd.at(vi);
//       defer v_col.deinit(alloc);
//       const new_col = N(V).init(alloc, nrows) catch return V{ .err = .memory };
//       @memset(new_col.slice(), .blank);
//       for (0..nrows) |ri| {
//         new_col.slice()[ri] = if (match_rows[ri]) |ki| v_col.at(ki) else t_col.at(ri);
//       }
//       out_data.slice()[ti] = try util.promote(alloc, new_col);
//     } else {
//       out_data.slice()[ti] = t_data.at(ti);
//     }
//   }

//   // Build extra value columns (0 when no match).
//   for (extra_vi, 0..) |vi, ei| {
//     const v_col = vd.at(vi);
//     defer v_col.deinit(alloc);
//     const new_col = N(V).init(alloc, nrows) catch return V{ .err = .memory };
//     @memset(new_col.slice(), .blank);
//     for (0..nrows) |ri| {
//       new_col.slice()[ri] = if (match_rows[ri]) |ki| v_col.at(ki) else .{ .i = 0 };
//     }
//     out_data.slice()[ntcols + ei] = try util.promote(alloc, new_col);
//   }

//   // Build output column names.
//   const out_cols = N(V).init(alloc, out_ncols) catch return V{ .err = .memory };
//   @memset(out_cols.slice(), .blank);
//   for (0..ntcols) |ti| out_cols.slice()[ti] = t_cols.at(ti);
//   for (extra_vi, 0..) |vi, ei| out_cols.slice()[ntcols + ei] = vc.at(vi);
//   const out_cols_v = try util.promote(alloc, out_cols);

//   return .{ .M = try Table.init(alloc, out_cols_v, .{ .L = out_data }) };
// }

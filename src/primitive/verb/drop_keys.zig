const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const pair = @import("pair.zig");
const promote = @import("../promote.zig").promote;

/// X_d: drop keys from a dict.
pub const DropKeys = struct {
  pub const op = .@"_";
  _s_m: VM.Dyad = dropKeys,
  _S_m: VM.Dyad = dropKeys,
  _i_m: VM.Dyad = dropKeys,
  _I_m: VM.Dyad = dropKeys,
  _f_m: VM.Dyad = dropKeys,
  _F_m: VM.Dyad = dropKeys,
  _c_m: VM.Dyad = dropKeys,
  _C_m: VM.Dyad = dropKeys,
};

pub fn dropKeys(vm: *VM, x: V, y: V) V {
  // A keyed table (utable): `x _ u` drops the ROW(s) whose key column value is in x
  // (entity despawn), not a dict key. Filter both the key and value tables row-wise.
  if (y.m.av().tag() == .M) return dropUTableRows(vm, x, y);
  const dav = y.m.av();
  const dbv = y.m.bv();
  const dict_len = dav.len();
  const xlen = x.len();
  var keep_keys: std.ArrayList(V) = .empty;
  var keep_vals: std.ArrayList(V) = .empty;
  defer { keep_keys.deinit(vm.alloc); keep_vals.deinit(vm.alloc); }
  keep_keys.ensureTotalCapacity(vm.alloc, dict_len) catch return V{ .err = .memory };
  keep_vals.ensureTotalCapacity(vm.alloc, dict_len) catch return V{ .err = .memory };
  for (0..dict_len) |i| {
    const k1 = dav.at(i);
    var found = false;
    for (0..xlen) |j| {
      const xv = x.at(j);
      defer xv.deinit(vm.alloc);
      if (k1.eq(xv)) { found = true; break; }
    }
    if (!found) {
      keep_keys.appendAssumeCapacity(k1);
      keep_vals.appendAssumeCapacity(dbv.at(i));
    } else k1.deinit(vm.alloc);
  }
  const n = keep_keys.items.len;
  // Symbol single-key: pass scalars so the [k:v] formatter shows the value directly (not enlisted)
  if (n == 1 and keep_keys.items[0].tag() == .s) {
    return pair.dict(vm, keep_keys.items[0], keep_vals.items[0]);
  }
  const rk = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(rk.slice(), keep_keys.items);
  const rv = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(rv.slice(), keep_vals.items);
  // n>1: promote keys and vals so e.g. int atoms collapse to a typed vector (1 3 not (1;3))
  // n==1 non-symbol: keep as L so key and val each display as enlisted scalars (,3!,"c")
  const keys_v: V = if (n > 1) promote(vm.alloc, rk) else .{ .L = rk };
  const vals_v: V = if (n > 1) promote(vm.alloc, rv) else .{ .L = rv };
  const res = pair.dict(vm, keys_v, vals_v);
  keys_v.deinit(vm.alloc);
  vals_v.deinit(vm.alloc);
  return res;
}

// `x _ u` for a utable: keep rows whose (single) key column value is NOT in x.
fn dropUTableRows(vm: *VM, x: V, u: V) V {
  const alloc = vm.alloc;
  const key_m = u.m.av();                 // M: key columns
  const val_m = u.m.bv();                 // M: value columns
  const kcol = key_m.M.bv().at(0);        // first (single) key column
  defer kcol.deinit(alloc);
  const nrows = kcol.len();
  const mask = N(bool).init(alloc, nrows) catch return V{ .err = .memory };
  defer mask.deinit(alloc);
  var nkeep: usize = 0;
  for (0..nrows) |r| {
    const cell = kcol.at(r); defer cell.deinit(alloc);
    var drop = false;
    for (0..x.len()) |j| {
      const xv = x.at(j); defer xv.deinit(alloc);
      if (cell.eq(xv)) { drop = true; break; }
    }
    mask.slice()[r] = !drop;
    if (!drop) nkeep += 1;
  }
  const nk = filterTable(alloc, key_m, mask.slice(), nkeep);
  const nv = filterTable(alloc, val_m, mask.slice(), nkeep);
  return .{ .m = Dict.init(alloc, nk, nv) catch return V{ .err = .memory } };
}

// Keep the masked rows of a table M, column by column (each column stays typed).
fn filterTable(alloc: Alloc, t: V, mask: []const bool, nkeep: usize) V {
  const names = t.M.av();
  const cols = t.M.bv();
  const ncol = names.len();
  const out = N(V).init(alloc, ncol) catch return V{ .err = .memory };
  for (0..ncol) |c| {
    const col = cols.at(c); defer col.deinit(alloc);
    out.slice()[c] = filterCol(alloc, col, mask, nkeep);
  }
  return .{ .M = Dict.init(alloc, names.ref(), .{ .L = out }) catch return V{ .err = .memory } };
}

fn filterCol(alloc: Alloc, col: V, mask: []const bool, nkeep: usize) V {
  switch (col) {
    inline .B, .I, .F, .S, .C => |n, k| {
      const r = N(K.backing(k)).init(alloc, nkeep) catch return V{ .err = .memory };
      var w: usize = 0;
      for (n.slice(), mask) |v, keep| if (keep) { r.slice()[w] = v; w += 1; };
      return V.wrap(k, r);
    },
    .L => |n| {
      const r = N(V).init(alloc, nkeep) catch return V{ .err = .memory };
      var w: usize = 0;
      for (n.slice(), mask) |v, keep| if (keep) { r.slice()[w] = v.ref(); w += 1; };
      return V{ .L = r };
    },
    else => return col.ref(),
  }
}

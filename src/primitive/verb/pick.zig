const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const promote = @import("../promote.zig").promote;
const emptyOf = @import("../promote.zig").emptyOf;

const value = @import("../../noun/value.zig");

pub const Pick = struct {
  pub const op = .@"@";

  _B_b: VM.Dyad = pickBoolFn,
  _I_b: VM.Dyad = pickBoolFn,
  _F_b: VM.Dyad = pickBoolFn,
  _N_b: VM.Dyad = pickBoolFn,
  _D_b: VM.Dyad = pickBoolFn,
  _H_b: VM.Dyad = pickBoolFn,
  _C_b: VM.Dyad = pickBoolFn,
  _L_b: VM.Dyad = pickBoolFn,

  _B_B: VM.Dyad = pickMaskTyped(.B),
  _I_B: VM.Dyad = pickMaskTyped(.I),
  _F_B: VM.Dyad = pickMaskTyped(.F),
  _N_B: VM.Dyad = pickMaskTyped(.N),
  _D_B: VM.Dyad = pickMaskTyped(.D),
  _H_B: VM.Dyad = pickMaskTyped(.H),
  _C_B: VM.Dyad = pickMaskTyped(.C),
  _L_B: VM.Dyad = pickMaskFn,

  _B_i: VM.Dyad = pickAtomFn,
  _I_i: VM.Dyad = pickAtomFn,
  _F_i: VM.Dyad = pickAtomFn,
  _N_i: VM.Dyad = pickAtomFn,
  _D_i: VM.Dyad = pickAtomFn,
  _H_i: VM.Dyad = pickAtomFn,
  _S_i: VM.Dyad = pickAtomFn,
  _C_i: VM.Dyad = pickAtomFn,
  _L_i: VM.Dyad = pickAtomFn,

  _B_I: VM.Dyad = pickVecTyped(.B),
  _I_I: VM.Dyad = pickVecTyped(.I),
  _F_I: VM.Dyad = pickVecTyped(.F),
  _N_I: VM.Dyad = pickVecTyped(.N),
  _D_I: VM.Dyad = pickVecTyped(.D),
  _H_I: VM.Dyad = pickVecTyped(.H),
  _S_I: VM.Dyad = pickVecTyped(.S),
  _C_I: VM.Dyad = pickVecTyped(.C),
  _L_I: VM.Dyad = pickVecFn,

  // x@(y0;y1;...) → (x@y0; x@y1; ...) — index x at each element of list y
  _B_L: VM.Dyad = pickListFn,
  _I_L: VM.Dyad = pickListFn,
  _F_L: VM.Dyad = pickListFn,
  _N_L: VM.Dyad = pickListFn,
  _D_L: VM.Dyad = pickListFn,
  _H_L: VM.Dyad = pickListFn,
  _C_L: VM.Dyad = pickListFn,
  _L_L: VM.Dyad = pickListFn,

  _S_s: VM.Dyad = pickSymAtomFn,
  _S_S: VM.Dyad = pickSymVecFn,
};


fn pickTypedVec(comptime xk: K, alloc: Alloc, x: V, indices: []const i32) V {
  const T = comptime xk.backing();
  const src = @field(x, @tagName(xk)).slice();
  const res = N(T).init(alloc, indices.len) catch return V{ .err = .memory };
  for (indices, 0..) |idx, k| {
    if (idx < 0 or idx >= @as(i32, @intCast(src.len))) {
      res.deinit(alloc);
      return .{ .err = .length };
    }
    res.slice()[k] = src[@intCast(idx)];
  }
  return @unionInit(V, @tagName(xk), res);
}

fn pickIntVec(alloc: Alloc, x: V, indices: []const i32) V {
  return switch (x.tag()) {
    .B => pickTypedVec(.B, alloc, x, indices),
    .I => pickTypedVec(.I, alloc, x, indices),
    .F => pickTypedVec(.F, alloc, x, indices),
    .C => pickTypedVec(.C, alloc, x, indices),
    .S => pickTypedVec(.S, alloc, x, indices),
    else => blk: {
      // Generic list: build N(V) and promote
      const res = N(V).init(alloc, indices.len) catch break :blk V{ .err = .memory };
      @memset(res.slice(), .blank);
      const length = x.len();
      for (indices, 0..) |idx, k| {
        if (idx < 0 or idx >= @as(i32, @intCast(length))) {
          for (res.slice()[0..k]) |*v| v.deinit(alloc);
          res.deinit(alloc);
          break :blk .{ .err = .length };
        }
        res.slice()[k] = x.at(@intCast(idx));
      }
      break :blk promote(alloc, res);
    },
  };
}

fn pickElement(alloc: Alloc, x: V, y: V) V {
  return switch (y.tag()) {
    .b => pickAtom(x, if (y.b) 1 else 0),
    .i => pickAtom(x, y.i),
    .B => pickMask(alloc, x, y.B.slice()),
    .I => pickIntVec(alloc, x, y.I.slice()),
    .L => blk: {
      const items = y.L.slice();
      const res = N(V).init(alloc, items.len) catch break :blk V{ .err = .memory };
      @memset(res.slice(), .blank);
      for (items, 0..) |item, k| {
        const r = pickElement(alloc, x, item);
        if (r.tag() == .err) {
          for (res.slice()[0..k]) |*v| v.deinit(alloc);
          res.deinit(alloc);
          break :blk r;
        }
        res.slice()[k] = r;
      }
      break :blk promote(alloc, res);
    },
    else => .{ .err = .@"type" },
  };
}

fn pickListFn(vm: *VM, x: V, y: V) V {
  const items = y.L.slice();
  const res = N(V).init(vm.alloc, items.len) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (items, 0..) |item, k| {
    const r = pickElement(vm.alloc, x, item);
    if (r.tag() == .err) {
      for (res.slice()[0..k]) |*v| v.deinit(vm.alloc);
      res.deinit(vm.alloc);
      return r;
    }
    res.slice()[k] = r;
  }
  return promote(vm.alloc, res);
}

fn pickBoolFn(_: *VM, x: V, y: V) V  { return x.at(if (y.b) 1 else 0); }
fn pickMaskFn(vm: *VM, x: V, y: V) V { return pickMask(vm.alloc, x, y.B.slice()); }
pub fn pickAtomFn(_: *VM, x: V, y: V) V  { return pickAtom(x, y.i); }
pub fn pickVecFn(vm: *VM, x: V, y: V) V  { return pickVec(vm.alloc, x, y.I.slice()); }

fn pickVecTyped(comptime xk: K) VM.Dyad {
  comptime std.debug.assert(xk.isVec());
  return struct {
    const T = K.backing(xk);
    fn f(vm: *VM, x: V, y: V) V {
      const src = @field(x, @tagName(xk)).slice();
      const indices = y.I.slice();
      const res = N(T).init(vm.alloc, indices.len) catch return V{ .err = .memory };
      for (indices, 0..) |idx, k| {
        if (idx < 0 or idx >= @as(i32, @intCast(src.len))) {
          res.deinit(vm.alloc);
          return .{ .err = .length };
        }
        res.slice()[k] = src[@intCast(idx)];
      }
      return @unionInit(V, @tagName(xk), res);
    }
  }.f;
}

fn pickMaskTyped(comptime xk: K) VM.Dyad {
  comptime std.debug.assert(xk.isVec());
  return struct {
    const T = K.backing(xk);
    fn f(vm: *VM, x: V, y: V) V {
      const src = @field(x, @tagName(xk)).slice();
      const mask = y.B.slice();
      if (src.len == 2) {
        const res = N(T).init(vm.alloc, mask.len) catch return V{ .err = .memory };
        for (mask, 0..) |m, k| res.slice()[k] = src[if (m) @as(usize, 1) else 0];
        return @unionInit(V, @tagName(xk), res);
      }
      if (mask.len != src.len) return .{ .err = .length };
      var count: usize = 0;
      for (mask) |m| if (m) { count += 1; };
      const res = N(T).init(vm.alloc, count) catch return V{ .err = .memory };
      var j: usize = 0;
      for (mask, src) |m, v| if (m) { res.slice()[j] = v; j += 1; };
      return @unionInit(V, @tagName(xk), res);
    }
  }.f;
}
fn pickSymAtomFn(_: *VM, x: V, y: V) V  { return pickSymAtom(x, y.s); }
fn pickSymVecFn(vm: *VM, x: V, y: V) V  { return pickSymVec(vm.alloc, x, y.S.slice()); }
pub fn pickDictSymFn(vm: *VM, x: V, y: V) V  {
  if (isUTable(x.m)) {
    // u@`col: a value-column name reads that whole column (so a system can do u`px);
    // any other symbol falls through to a key lookup (e.g. a symbol-keyed utable).
    const col = pickTableCol(x.m.bv().M, y.s);
    if (col.tag() != .blank) return col;
    return pickUTable(vm.alloc, x.m, y);
  }
  return pickDictSym(x.m, y.s);
}
// m@i: a utable keyed by an int column looks the key up; a plain dict indexes positionally.
pub fn pickDictIntFn(vm: *VM, x: V, y: V) V  {
  if (isUTable(x.m)) return pickUTable(vm.alloc, x.m, y);
  return pickAtom(x, y.i);
}
pub fn pickDictSymVecFn(vm: *VM, x: V, y: V) V { return pickDictSymVec(vm.alloc, x.m, y.S.slice()); }
pub fn pickDictKeyFn(vm: *VM, x: V, y: V) V { return pickDictKey(vm.alloc, x.m, y); }
pub fn pickDictKeyVecFn(vm: *VM, x: V, y: V) V {
  const res = N(V).init(vm.alloc, y.len()) catch return V{ .err = .memory };
  for (0..y.len()) |k| {
    const key = y.at(k);
    defer key.deinit(vm.alloc);
    res.slice()[k] = pickDictKey(vm.alloc, x.m, key);
  }
  return promote(vm.alloc, res);
}
pub fn pickTableRowFn(vm: *VM, x: V, y: V) V  { return pickTableRow(vm.alloc, x.M, y.i); }
pub fn pickTableRowVecFn(vm: *VM, x: V, y: V) V { return pickTableRowVec(vm.alloc, x, y.I.slice()); }
pub fn pickTableColFn(_: *VM, x: V, y: V) V  { return pickTableCol(x.M, y.s); }
pub fn pickTableColVecFn(vm: *VM, x: V, y: V) V { return pickTableColVec(vm.alloc, x, y.S.slice()); }


fn pickAtom(x: V, idx: i32) V {
  if (idx < 0 or idx >= @as(i32, @intCast(x.len()))) return .{ .err = .length };
  return x.at(@intCast(idx));
}

fn pickVec(alloc: Alloc, x: V, indices: []const i32) V {
  const length = x.len();
  // Empty selection keeps the source's type (promote can't infer it from 0
  // elements → it would return an untyped `L`, breaking downstream =/&/columns).
  if (indices.len == 0) return emptyOf(alloc, x.tag());
  const res = N(V).init(alloc, indices.len) catch return V{ .err = .memory };
  @memset(res.slice(), .blank);
  for (indices, 0..) |idx, k| {
    if (idx < 0 or idx >= @as(i32, @intCast(length))) {
      for (res.slice()[0..k]) |*v| v.deinit(alloc);
      res.deinit(alloc);
      return .{ .err = .length };
    }
    res.slice()[k] = x.at(@intCast(idx));
  }
  return promote(alloc, res);
}

fn pickMask(alloc: Alloc, x: V, mask: []const bool) V {
  const length = x.len();
  if (length == 2) {
    const res = N(V).init(alloc, mask.len) catch return V{ .err = .memory };
    for (mask, 0..) |m, k| res.slice()[k] = x.at(@as(usize, if (m) 1 else 0));
    return promote(alloc, res);
  }
  if (mask.len != length) return .{ .err = .length };
  var res_list: std.ArrayList(V) = .empty;
  defer res_list.deinit(alloc);
  res_list.ensureTotalCapacity(alloc, mask.len) catch return V{ .err = .memory };
  for (mask, 0..) |m, k| if (m) res_list.appendAssumeCapacity(x.at(k));
  if (res_list.items.len == 0) return emptyOf(alloc, x.tag());
  const res = N(V).init(alloc, res_list.items.len) catch return V{ .err = .memory };
  @memcpy(res.slice(), res_list.items);
  res_list.items.len = 0;
  return promote(alloc, res);
}

fn pickSymAtom(x: V, s: u32) V {
  for (x.S.slice(), 0..) |k, idx| if (k == s) return x.at(idx);
  return .blank;
}

fn pickSymVec(alloc: Alloc, x: V, keys: []const u32) V {
  const res = N(V).init(alloc, keys.len) catch return V{ .err = .memory };
  for (keys, 0..) |s, k| res.slice()[k] = pickSymAtom(x, s);
  return promote(alloc, res);
}

fn pickDictSym(m: Dict, s: u32) V {
  const keys = m.av();
  const vals = m.bv();
  if (keys.tag() == .S) {
    for (keys.S.slice(), 0..) |k, idx| if (k == s) return vals.at(idx);
  } else if (keys.tag() == .s and keys.s == s) return vals.at(0);
  return .blank;
}

// Generic key lookup for non-symbol/int key types (chars, floats, …): scan the
// key array comparing each candidate with `.eq()` and return its value (or the
// null `.blank` on a miss). Symbols keep their dedicated u32 path; ints stay
// positional (see pickDictIntFn) so `(1 2 3!…)0` indexes by position.
fn pickDictKey(alloc: Alloc, m: Dict, key: V) V {
  const keys = m.av();
  const vals = m.bv();
  for (0..keys.len()) |idx| {
    const k = keys.at(idx);
    defer k.deinit(alloc);
    if (k.eq(key)) return vals.at(idx);
  }
  return .blank;
}

fn pickDictSymVec(alloc: Alloc, m: Dict, keys: []const u32) V {
  const res = N(V).init(alloc, keys.len) catch return V{ .err = .memory };
  for (keys, 0..) |s, k| res.slice()[k] = pickDictSym(m, s);
  return promote(alloc, res);
}

// ── keyed table (utable) lookup: an `m` dict whose keys are a table (M) ──────────
// u@key finds the row whose (single) key column equals `key and returns its value row.
pub fn isUTable(m: Dict) bool { return m.av().tag() == .M; }

fn uFindRow(alloc: Alloc, key_table: Dict, key: V) i32 {
  const cols = key_table.bv();            // list of key columns
  if (cols.len() == 0) return -1;
  const col = cols.at(0);                 // single (first) key column
  defer col.deinit(alloc);
  const nrows = col.len();
  var r: usize = 0;
  while (r < nrows) : (r += 1) {
    const cell = col.at(r);
    defer cell.deinit(alloc);
    if (cell.eq(key)) return @intCast(r);
  }
  return -1;
}

fn pickUTable(alloc: Alloc, u: Dict, key: V) V {
  const idx = uFindRow(alloc, u.av().M, key);
  if (idx < 0) return .blank;             // absent key → null
  return pickTableRow(alloc, u.bv().M, idx);
}

fn pickTableRow(alloc: Alloc, t: Dict, idx: i32) V {
  const keys = t.av();
  const vals = t.bv();
  const ncols = keys.len();
  if (ncols == 0) return .{ .err = .length };
  const first_col = vals.at(0);
  const nrows: i32 = @intCast(first_col.len());
  first_col.deinit(alloc);
  if (idx < 0 or idx >= nrows) return .{ .err = .length };
  const row_vals = N(V).init(alloc, ncols) catch return V{ .err = .memory };
  for (0..ncols) |j| {
    const col = vals.at(j);
    defer col.deinit(alloc);
    row_vals.slice()[j] = col.at(@intCast(idx));
  }
  const dict = Dict.init(alloc, keys.ref(), .{ .L = row_vals }) catch return V{ .err = .memory };
  return V{ .m = dict };
}

// Select rows by an index vector → a new table. Gathers each column directly
// (no per-row dict materialization), so it is leak-free and allocation-light.
fn pickTableRowVec(alloc: Alloc, x: V, indices: []const i32) V {
  const keys = x.M.av();
  const vals = x.M.bv();
  const ncols = keys.len();
  if (ncols == 0) return .{ .err = .length };
  const first_col = vals.at(0);
  const nrows: i32 = @intCast(first_col.len());
  first_col.deinit(alloc);
  for (indices) |idx| if (idx < 0 or idx >= nrows) return .{ .err = .length };
  const res_vals = N(V).init(alloc, ncols) catch return V{ .err = .memory };
  for (0..ncols) |j| {
    const col = vals.at(j);
    defer col.deinit(alloc);
    res_vals.slice()[j] = pickVec(alloc, col, indices);
  }
  return V{ .M = Dict.init(alloc, keys.ref(), promote(alloc, res_vals)) catch return V{ .err = .memory } };
}

fn pickTableCol(t: Dict, s: u32) V {
  const keys = t.av();
  const vals = t.bv();
  if (keys.tag() == .S) {
    for (keys.S.slice(), 0..) |k, idx| if (k == s) return vals.at(idx);
  } else if (keys.tag() == .s and keys.s == s) return vals.at(0);
  return .blank;
}

// t`a`b → the selected columns as a LIST (one per name), the same shape a dict gives for
// m`a`b. This makes column arithmetic positional — `(t`px`py)+t`vx`vy` pairs px with vx —
// and round-trips with the multi-column amend `t[`px`py]:vals`. (A sub-TABLE projection is
// `\`a\`b#t`.)
fn pickTableColVec(alloc: Alloc, x: V, keys: []const u32) V {
  const res_vals = N(V).init(alloc, keys.len) catch return V{ .err = .memory };
  for (keys, 0..) |s, k| res_vals.slice()[k] = pickTableCol(x.M, s);
  return promote(alloc, res_vals);
}

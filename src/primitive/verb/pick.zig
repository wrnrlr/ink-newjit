const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

const value = @import("../../noun/value.zig");
const flip = @import("flip.zig").flip;

pub const Pick = struct {
  pub const op = .@"@";

  _B_b: util.DyadFn = pickBoolFn,
  _I_b: util.DyadFn = pickBoolFn,
  _F_b: util.DyadFn = pickBoolFn,
  _C_b: util.DyadFn = pickBoolFn,
  _L_b: util.DyadFn = pickBoolFn,

  _B_B: util.DyadFn = pickMaskTyped(.B),
  _I_B: util.DyadFn = pickMaskTyped(.I),
  _F_B: util.DyadFn = pickMaskTyped(.F),
  _C_B: util.DyadFn = pickMaskTyped(.C),
  _L_B: util.DyadFn = pickMaskFn,

  _B_i: util.DyadFn = pickAtomFn,
  _I_i: util.DyadFn = pickAtomFn,
  _F_i: util.DyadFn = pickAtomFn,
  _S_i: util.DyadFn = pickAtomFn,
  _C_i: util.DyadFn = pickAtomFn,
  _L_i: util.DyadFn = pickAtomFn,

  _B_I: util.DyadFn = pickVecTyped(.B),
  _I_I: util.DyadFn = pickVecTyped(.I),
  _F_I: util.DyadFn = pickVecTyped(.F),
  _S_I: util.DyadFn = pickVecTyped(.S),
  _C_I: util.DyadFn = pickVecTyped(.C),
  _L_I: util.DyadFn = pickVecFn,

  // x@(y0;y1;...) → (x@y0; x@y1; ...) — index x at each element of list y
  _B_L: util.DyadFn = pickListFn,
  _I_L: util.DyadFn = pickListFn,
  _F_L: util.DyadFn = pickListFn,
  _C_L: util.DyadFn = pickListFn,
  _L_L: util.DyadFn = pickListFn,

  _S_s: util.DyadFn = pickSymAtomFn,
  _S_S: util.DyadFn = pickSymVecFn,
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

fn pickVecTyped(comptime xk: K) util.DyadFn {
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

fn pickMaskTyped(comptime xk: K) util.DyadFn {
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
pub fn pickDictSymFn(_: *VM, x: V, y: V) V  { return pickDictSym(x.m, y.s); }
pub fn pickDictSymVecFn(vm: *VM, x: V, y: V) V { return pickDictSymVec(vm.alloc, x.m, y.S.slice()); }
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

fn pickDictSymVec(alloc: Alloc, m: Dict, keys: []const u32) V {
  const res = N(V).init(alloc, keys.len) catch return V{ .err = .memory };
  for (keys, 0..) |s, k| res.slice()[k] = pickDictSym(m, s);
  return promote(alloc, res);
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

fn pickTableRowVec(alloc: Alloc, x: V, indices: []const i32) V {
  const n = indices.len;
  const res = N(V).init(alloc, n) catch return V{ .err = .memory };
  for (indices, 0..) |idx, k| res.slice()[k] = pickTableRow(alloc, x.M, idx);
  return flip(alloc, .{ .L = res });
}

fn pickTableCol(t: Dict, s: u32) V {
  const keys = t.av();
  const vals = t.bv();
  if (keys.tag() == .S) {
    for (keys.S.slice(), 0..) |k, idx| if (k == s) return vals.at(idx);
  } else if (keys.tag() == .s and keys.s == s) return vals.at(0);
  return .blank;
}

fn pickTableColVec(alloc: Alloc, x: V, keys: []const u32) V {
  const n = keys.len;
  const res_keys = N(u32).init(alloc, n) catch return V{ .err = .memory };
  const res_vals = N(V).init(alloc, n) catch return V{ .err = .memory };
  for (keys, 0..) |s, k| {
    res_keys.slice()[k] = s;
    res_vals.slice()[k] = pickTableCol(x.M, s);
  }
  const dict = Dict.init(alloc, .{ .S = res_keys }, promote(alloc, res_vals)) catch return V{ .err = .memory };
  return V{ .M = dict };
}

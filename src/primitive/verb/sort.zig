const std = @import("std");
const radix = @import("sort/radixsort.zig");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const K = @import("../../noun/class.zig").K;
const VM = @import("../../runtime/vm.zig").VM;
const Dict = @import("../../noun/dict.zig").Dict;
const pick = @import("pick.zig");
const h = @import("helper.zig");
const Alloc = std.mem.Allocator;

// `<M`/`>M` grade a table like any other array — the row indices that order it,
// so `t@<t` sorts. `<m`/`>m` on a dict instead hand back the dict itself with its
// entries reordered by value (`<="mississippi"` → the group dict with its
// shortest run first): a dict's "indices" are its keys, and returning those would
// lose the values that did the ordering.
fn asc(vm: *VM, x: V) V { return grade(vm, x, false); }
fn dsc(vm: *VM, x: V) V { return grade(vm, x, true); }

fn grade(vm: *VM, x: V, desc: bool) V {
  return switch (x) {
    .m => sortDict(vm, x, desc),
    .M => gradeTable(vm, x, desc),
    else => sortIndices(vm.alloc, x, desc),
  };
}

/// Exported for use by other verbs that need to fall back to grade operations.
pub fn gradeDescend(vm: *VM, x: V) V { return dsc(vm, x); }
pub fn gradeAscend(vm: *VM, x: V) V { return asc(vm, x); }

// Grade-up (`<`) has no scalar-symbol slot; grade-down (`>`) does. Kept exact.
const asc_kinds = [_]K{ .b, .i, .f, .n, .d, .h, .c, .m, .B, .I, .F, .N, .D, .H, .S, .C, .M, .L };
const dsc_kinds = [_]K{ .b, .i, .f, .n, .d, .h, .s, .c, .m, .B, .I, .F, .N, .D, .H, .S, .C, .M, .L };
pub const Ascend  = h._Y(.@"<", &asc_kinds, asc);
pub const Descend = h._Y(.@">", &dsc_kinds, dsc);

// NaN-aware scalar order: NaNs sort below everything and compare equal to each
// other (matches the grade semantics the vector/float paths rely on).
pub inline fn orderFloat(a: anytype, b: @TypeOf(a)) std.math.Order {
  const an = std.math.isNan(a); const bn = std.math.isNan(b);
  if (an and bn) return .eq;
  if (an) return .lt;
  if (bn) return .gt;
  return std.math.order(a, b);
}

// Lexicographic order over two same-typed slices; shorter-is-less on a common
// prefix. Floats use the NaN-aware order, bools compare as 0/1.
fn orderElems(comptime T: type, sa: []const T, sb: []const T) std.math.Order {
  const n = @min(sa.len, sb.len);
  for (sa[0..n], sb[0..n]) |ai, bi| {
    const o = if (comptime @typeInfo(T) == .float) orderFloat(ai, bi)
              else if (comptime T == bool) std.math.order(@intFromBool(ai), @intFromBool(bi))
              else std.math.order(ai, bi);
    if (o != .eq) return o;
  }
  return std.math.order(sa.len, sb.len);
}

/// Total order over arbitrary values — the one `<`/`>` grade a general
/// list by. Exported so `=`/`freq` can order their general-list keys the same way.
pub fn compareV(a: V, b: V) std.math.Order {
  const at = a.tag();
  const bt = b.tag();
  if (at != bt) return std.math.order(@intFromEnum(at), @intFromEnum(bt));
  return switch (at) {
    .i => std.math.order(a.i, b.i),
    .f => orderFloat(a.f, b.f),
    .d => orderFloat(a.d, b.d),
    .h => orderFloat(a.h, b.h),
    .c => std.math.order(a.c, b.c),
    .n => std.math.order(a.n, b.n),
    .s => std.math.order(a.s, b.s),
    .b => std.math.order(@intFromBool(a.b), @intFromBool(b.b)),
    .I => orderElems(i32,  a.I.slice(), b.I.slice()),
    .N => orderElems(u32,  a.N.slice(), b.N.slice()),
    .F => orderElems(f32,  a.F.slice(), b.F.slice()),
    .D => orderElems(f64,  a.D.slice(), b.D.slice()),
    .H => orderElems(f16,  a.H.slice(), b.H.slice()),
    .B => orderElems(bool, a.B.slice(), b.B.slice()),
    .C => std.mem.order(u8, a.C.slice(), b.C.slice()),
    .L => blk: {
      const la = a.L.slice(); const lb = b.L.slice();
      const n = @min(la.len, lb.len);
      for (la[0..n], lb[0..n]) |ai, bi| { const o = compareV(ai, bi); if (o != .eq) break :blk o; }
      break :blk std.math.order(la.len, lb.len);
    },
    else => .eq,
  };
}

fn Context(comptime T: type) type {
  return struct {
    data: T,
    desc: bool,
    fn cmp(self: @This(), lhs: usize, rhs: usize) bool {
      const a = self.data[lhs];
      const b = self.data[rhs];
      const VType = std.meta.Child(T);
      if (comptime @typeInfo(VType) == .float) {
        const a_nan = std.math.isNan(a);
        const b_nan = std.math.isNan(b);
        if (a_nan and !b_nan) return !self.desc;
        if (!a_nan and b_nan) return self.desc;
        if (a_nan and b_nan) return false;
      }
      if (a == b) return false;
      if (comptime VType == bool) return if (self.desc) a else b;
      return if (self.desc) a > b else a < b;
    }
  };
}

pub fn sortIndices(alloc: Alloc, v: V, desc: bool) V {
  if (v.isAtom()) {
    const res = N(i32).init(alloc, 1) catch return V{ .err = .memory };
    res.slice()[0] = 0;
    return .{ .I = res };
  }

  const length = v.len();
  var indices = N(i32).init(alloc, length) catch return V{ .err = .memory };
  var idx_buf = alloc.alloc(usize, length) catch {
    (V{ .I = indices }).deinit(alloc);
    return V{ .err = .memory };
  };
  defer alloc.free(idx_buf);
  for (0..length) |i| idx_buf[i] = i;

  switch (v) {
    .I => |n| radix.sortI32(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    .S => |n| radix.sortU32(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    .N => |n| radix.sortU32(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    .C => |n| radix.sortU8(alloc, idx_buf, n.slice(), desc) catch return V{ .err = .memory },
    inline .F, .B, .D, .H => |n| {
      const Ctx = Context(@TypeOf(n.slice()));
      std.sort.block(usize, idx_buf, Ctx{ .data = n.slice(), .desc = desc }, Ctx.cmp);
    },
    .L => |n| {
      const LCtx = struct {
        data: []const V, desc: bool,
        fn cmp(self: @This(), lhs: usize, rhs: usize) bool {
          const ord = compareV(self.data[lhs], self.data[rhs]);
          return if (self.desc) ord == .gt else ord == .lt;
        }
      };
      std.sort.block(usize, idx_buf, LCtx{ .data = n.slice(), .desc = desc }, LCtx.cmp);
    },
    else => return .{ .err = .@"type" },
  }

  const res_slice = indices.slice();
  for (idx_buf, 0..) |idx, i| res_slice[i] = @intCast(idx);
  return .{ .I = indices };
}

// ── mapping types ─────────────────────────────────────────────────────────────

// Reorder a dict's entries by its values, keeping key↔value pairing. A keyed
// table (`m` whose halves are both tables) orders by the value table's rows, so
// the key rows follow along.
fn sortDict(vm: *VM, x: V, desc: bool) V {
  const keys = x.m.av();
  const vals = x.m.bv();
  // A scalar-key dict holds its lone value unwrapped — nothing to reorder.
  if (keys.isAtom()) return x.ref();
  const g = gradeAny(vm, vals, desc);
  if (g.tag() == .err) return g;
  defer g.deinit(vm.alloc);
  const nk = pick.permute(vm, keys, g);
  if (nk.tag() == .err) return nk;
  const nv = pick.permute(vm, vals, g);
  if (nv.tag() == .err) { nk.deinit(vm.alloc); return nv; }
  const d = Dict.init(vm.alloc, nk, nv) catch {
    nk.deinit(vm.alloc); nv.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  return V{ .m = d };
}

// Grade a dict half: tables grade by row, everything else by element.
fn gradeAny(vm: *VM, v: V, desc: bool) V {
  if (v.tag() == .M) return gradeTable(vm, v, desc);
  return sortIndices(vm.alloc, v, desc);
}

// Row grade for a table: rows compare lexicographically over the columns, left
// to right, on the same scalar order the vector grades use. Stable, so rows
// equal on every column keep their original order in both directions.
fn gradeTable(vm: *VM, x: V, desc: bool) V {
  const ncols = x.M.av().len();
  const vals = x.M.bv();
  if (ncols == 0) return V{ .err = .length };
  const cols = vm.alloc.alloc(V, ncols) catch return V{ .err = .memory };
  defer {
    for (cols) |c| c.deinit(vm.alloc);
    vm.alloc.free(cols);
  }
  for (cols, 0..) |*c, j| c.* = vals.at(j);
  const nrows = cols[0].len();

  var idx_buf = vm.alloc.alloc(usize, nrows) catch return V{ .err = .memory };
  defer vm.alloc.free(idx_buf);
  for (0..nrows) |i| idx_buf[i] = i;
  const Ctx = struct {
    alloc: Alloc, cols: []const V, desc: bool,
    fn cmp(self: @This(), lhs: usize, rhs: usize) bool {
      for (self.cols) |c| {
        if (lhs >= c.len() or rhs >= c.len()) continue; // ragged column: skip it
        const a = c.at(lhs); defer a.deinit(self.alloc);
        const b = c.at(rhs); defer b.deinit(self.alloc);
        const ord = compareV(a, b);
        if (ord != .eq) return if (self.desc) ord == .gt else ord == .lt;
      }
      return false;
    }
  };
  std.sort.block(usize, idx_buf, Ctx{ .alloc = vm.alloc, .cols = cols, .desc = desc }, Ctx.cmp);

  const indices = N(i32).init(vm.alloc, nrows) catch return V{ .err = .memory };
  for (idx_buf, indices.slice()) |idx, *r| r.* = @intCast(idx);
  return .{ .I = indices };
}

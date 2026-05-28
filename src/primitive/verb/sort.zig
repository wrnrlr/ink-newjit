const std = @import("std");
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Alloc = std.mem.Allocator;
const util = @import("../../util.zig");

const mergesort = @import("sort/mergesort.zig");
const timsort = @import("sort/timsort.zig");
const radixsort = @import("sort/radixsort.zig");

fn asc(vm: *VM, x: V) V { return sortIndices(vm.alloc, x, false); }
fn dsc(vm: *VM, x: V) V { return sortIndices(vm.alloc, x, true); }

pub const Ascend = struct {
  pub const op = .@"<";
  _b: util.MonadFn = asc,
  _i: util.MonadFn = asc,
  _f: util.MonadFn = asc,
  _c: util.MonadFn = asc,
  _B: util.MonadFn = asc,
  _I: util.MonadFn = asc,
  _F: util.MonadFn = asc,
  _S: util.MonadFn = asc,
  _C: util.MonadFn = asc,
  _L: util.MonadFn = asc,
};

pub const Descend = struct {
  pub const op = .@">";
  _b: util.MonadFn = dsc,
  _i: util.MonadFn = dsc,
  _f: util.MonadFn = dsc,
  _s: util.MonadFn = dsc,
  _c: util.MonadFn = dsc,
  _B: util.MonadFn = dsc,
  _I: util.MonadFn = dsc,
  _F: util.MonadFn = dsc,
  _S: util.MonadFn = dsc,
  _C: util.MonadFn = dsc,
  _L: util.MonadFn = dsc,
};

fn compareV(a: V, b: V) std.math.Order {
  const at = a.tag();
  const bt = b.tag();
  if (at != bt) return std.math.order(@intFromEnum(at), @intFromEnum(bt));
  return switch (at) {
    .i => std.math.order(a.i, b.i),
    .f => blk: {
      const an = std.math.isNan(a.f);
      const bn = std.math.isNan(b.f);
      if (an and bn) break :blk .eq;
      if (an) break :blk .lt;
      if (bn) break :blk .gt;
      break :blk std.math.order(a.f, b.f);
    },
    .c => std.math.order(a.c, b.c),
    .b => std.math.order(@intFromBool(a.b), @intFromBool(b.b)),
    .s => std.math.order(a.s, b.s),
    .I => blk: {
      const sa = a.I.slice(); const sb = b.I.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| { const o = std.math.order(ai, bi); if (o != .eq) break :blk o; }
      break :blk std.math.order(sa.len, sb.len);
    },
    .F => blk: {
      const sa = a.F.slice(); const sb = b.F.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| {
        const an2 = std.math.isNan(ai); const bn2 = std.math.isNan(bi);
        if (an2 and bn2) continue;
        if (an2) break :blk .lt;
        if (bn2) break :blk .gt;
        const o = std.math.order(ai, bi); if (o != .eq) break :blk o;
      }
      break :blk std.math.order(sa.len, sb.len);
    },
    .C => blk: {
      const sa = a.C.slice(); const sb = b.C.slice();
      break :blk std.mem.order(u8, sa, sb);
    },
    .B => blk: {
      const sa = a.B.slice(); const sb = b.B.slice();
      const n = @min(sa.len, sb.len);
      for (sa[0..n], sb[0..n]) |ai, bi| { const o = std.math.order(@intFromBool(ai), @intFromBool(bi)); if (o != .eq) break :blk o; }
      break :blk std.math.order(sa.len, sb.len);
    },
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
        if (a_nan and b_nan) return true;
      }

      if (a == b) return true;
      if (comptime VType == bool) return if (self.desc) a else b;
      return if (self.desc) a > b else a < b;
    }
  };
}

pub fn sortIndices(alloc: Alloc, v: V, desc: bool) V {
  const length = v.len();

  if (v.isAtom()) {
    const res = N(i32).init(alloc, 1) catch return V{ .err = .memory };
    res.slice()[0] = 0;
    return .{ .I = res };
  }

  var indices = N(i32).init(alloc, length) catch return V{ .err = .memory };

  var idx_buffer = alloc.alloc(usize, length) catch {
    (V{ .I = indices }).deinit(alloc);
    return V{ .err = .memory };
  };
  defer alloc.free(idx_buffer);

  for (0..length) |i| idx_buffer[i] = i;

  switch (v) {
    // Integer: LSD radix sort — O(8n), no per-element allocations, fastest for large n
    .I => |n| radixsort.sortI64(alloc, idx_buffer, n.slice(), desc) catch return V{ .err = .memory },
    // Symbol hashes (u32): LSD radix sort
    .S => |n| radixsort.sortU64(alloc, idx_buffer, n.slice(), desc) catch return V{ .err = .memory },
    // Char (u8): LSD radix sort, single pass
    .C => |n| radixsort.sortU8(alloc, idx_buffer, n.slice(), desc) catch return V{ .err = .memory },
    // Float: timsort — handles NaN via cmp, great cache behaviour on real data
    .F => |n| {
      const Ctx = Context([]const f32);
      const ctx = Ctx{ .data = n.slice(), .desc = desc };
      timsort.sort(alloc, idx_buffer, ctx, Ctx.cmp) catch return V{ .err = .memory };
    },
    // Bool: timsort
    .B => |n| {
      const Ctx = Context([]const bool);
      const ctx = Ctx{ .data = n.slice(), .desc = desc };
      timsort.sort(alloc, idx_buffer, ctx, Ctx.cmp) catch return V{ .err = .memory };
    },
    .L => |n| {
      const LCtx = struct {
        data: []const V,
        desc: bool,
        fn cmp(ctx: @This(), lhs: usize, rhs: usize) bool {
          const ord = compareV(ctx.data[lhs], ctx.data[rhs]);
          if (ctx.desc) return ord != .lt;
          return ord != .gt;
        }
      };
      const ctx = LCtx{ .data = n.slice(), .desc = desc };
      timsort.sort(alloc, idx_buffer, ctx, LCtx.cmp) catch {
        (V{ .I = indices }).deinit(alloc);
        return V{ .err = .memory };
      };
    },
    else => return .{ .err = .@"type" },
  }

  const res_slice = indices.slice();
  for (idx_buffer, 0..) |idx, i| {
    res_slice[i] = @intCast(idx);
  }

  return .{ .I = indices };
}

test "ascend integers" {
  const alloc = std.testing.allocator;
  var i_vals = [_]i32{ 3, 1, 4, 1, 5, 9, 2 };
  var v_i = try V.Ints(alloc, &i_vals);
  defer v_i.deinit(alloc);
  var res = sortIndices(alloc, v_i, false);
  defer res.deinit(alloc);
  try std.testing.expectEqualSlices(i32, &.{ 1, 3, 6, 0, 2, 4, 5 }, res.I.slice());
}

test "descend integers" {
  const alloc = std.testing.allocator;
  var i_vals = [_]i32{ 3, 1, 4, 2 };
  var v_i = try V.Ints(alloc, &i_vals);
  defer v_i.deinit(alloc);
  var res = sortIndices(alloc, v_i, true);
  defer res.deinit(alloc);
  try std.testing.expectEqualSlices(i32, &.{ 2, 0, 3, 1 }, res.I.slice());
}

test "ascend floats with NaN" {
  const alloc = std.testing.allocator;
  var f_vals = [_]f32{ 1.1, std.math.nan(f32), 0.5 };
  var v_f = try V.Floats(alloc, &f_vals);
  defer v_f.deinit(alloc);
  var res = sortIndices(alloc, v_f, false);
  defer res.deinit(alloc);
  // NaN sorts first in ascending
  try std.testing.expectEqualSlices(i32, &.{ 1, 2, 0 }, res.I.slice());
}

test "ascend chars" {
  const alloc = std.testing.allocator;
  var c_vals = [_]u8{ 'c', 'a', 'b' };
  var v_c = try V.Chars(alloc, &c_vals);
  defer v_c.deinit(alloc);
  var res = sortIndices(alloc, v_c, false);
  defer res.deinit(alloc);
  try std.testing.expectEqualSlices(i32, &.{ 1, 2, 0 }, res.I.slice());
}

test "ascend atom" {
  const alloc = std.testing.allocator;
  const v = V{ .i = 42 };
  var res = sortIndices(alloc, v, false);
  defer res.deinit(alloc);
  try std.testing.expectEqual(@as(usize, 1), res.I.ptr.len);
  try std.testing.expectEqual(@as(i32, 0), res.I.slice()[0]);
}

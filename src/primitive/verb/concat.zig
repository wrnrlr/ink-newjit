const std = @import("std");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op2 = @import("../../noun/operator.zig").Op2;
const ArrayFlags = @import("../../noun/array.zig").ArrayFlags;
const h = @import("helper.zig");

// ── Kernel generators ─────────────────────────────────────────────────────────

// Handles any combination where at least one side is .L.
fn listKernel(comptime xk: K, comptime yk: K) util.DyadFn {
  return &struct {
    fn f(vm: *VM, x: V, y: V) V {
      const xl: usize = x.len();
      const yl: usize = y.len();
      const res = N(V).init(vm.alloc, xl + yl) catch return V{ .err = .memory };
      if (comptime xk == .L) {
        for (x.L.slice(), res.slice()[0..xl]) |v, *r| r.* = v.ref();
      } else if (comptime xk.isVec()) {
        for (0..xl) |i| res.slice()[i] = x.at(i);
      } else {
        res.slice()[0] = x.ref();
      }
      if (comptime yk == .L) {
        for (y.L.slice(), res.slice()[xl..]) |v, *r| r.* = v.ref();
      } else if (comptime yk.isVec()) {
        for (0..yl) |i| res.slice()[xl + i] = y.at(i);
      } else {
        res.slice()[xl] = y.ref();
      }
      return V{ .L = res };
    }
  }.f;
}

// Same-base-type pair: atom+atom → vec, atom+vec → vec, vec+atom → vec, vec+vec → vec.
//
// Fast path (xk is a vector): if x has rc==1 and spare capacity (cap-len ≥ yl)
// we write y into x.dataPtr()[xl..xl+yl] and bump x.len, returning x.ref().
// This makes `x = x, e` loops O(N) amortised — geometric growth comes from
// initWithCap on the slow path, which gives the next allocation enough headroom.
fn homoKernel(comptime xk: K, comptime yk: K) util.DyadFn {
  const VK: K = @enumFromInt((@intFromEnum(xk) & ~@as(u8, K.VEC_BIT)) | K.VEC_BIT);
  const T = K.backing(VK);
  return &struct {
    inline fn xcopy(dst: []T, x: V) void {
      if (comptime xk.isAtom()) dst[0] = @field(x, @tagName(xk))
      else @memcpy(dst, @field(x, @tagName(VK)).slice());
    }
    inline fn ycopy(dst: []T, y: V) void {
      if (comptime yk.isAtom()) dst[0] = @field(y, @tagName(yk))
      else @memcpy(dst, @field(y, @tagName(VK)).slice());
    }
    fn f(vm: *VM, x: V, y: V) V {
      const xl = x.len();
      const yl = y.len();
      // In-place append when xk is a vec and we own it exclusively.
      if (comptime xk.isVec()) {
        const xn = @field(x, @tagName(xk));
        if (xn.ptr.rc == 1 and !xn.hasFlag(ArrayFlags.immutable) and
            @as(usize, xn.ptr.cap) - @as(usize, xn.ptr.len) >= yl) {
          const dst_ptr = xn.dataPtr();
          ycopy(dst_ptr[xl .. xl + yl], y);
          xn.ptr.len = @intCast(xl + yl);
          return x.ref();
        }
      }
      const target = xl + yl;
      // 2× target gives the inner ceilPowerOfTwo enough room to land in the
      // next bucket up, so the next yl appends are O(1).
      const res = N(T).initWithCap(vm.alloc, target, target *| 2) catch return V{ .err = .memory };
      xcopy(res.slice()[0..xl], x);
      ycopy(res.slice()[xl..], y);
      return @unionInit(V, @tagName(VK), res);
    }
  }.f;
}

fn heteroConcat(vm: *VM, x: V, y: V) V {
  const res = N(V).init(vm.alloc, 2) catch return V{ .err = .memory };
  res.slice()[0] = x.ref();
  res.slice()[1] = y.ref();
  return V{ .L = res };
}

fn getConcatKernel(comptime xk: K, comptime yk: K) util.DyadFn {
  if (xk == .L or yk == .L) return listKernel(xk, yk);
  if ((xk.isAtom() or xk.isVec()) and (yk.isAtom() or yk.isVec())) {
    if ((@intFromEnum(xk) & ~@as(u8, K.VEC_BIT)) == (@intFromEnum(yk) & ~@as(u8, K.VEC_BIT)))
      return homoKernel(xk, yk);
  }
  return &heteroConcat;
}

// ── Concat struct ─────────────────────────────────────────────────────────────

// Excludes .m and .M — those are handled by DictMerge and Insert.
const concat_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len]K = undefined;
  var n: usize = 0;
  for (fields) |f| {
    const k: K = @enumFromInt(f.value);
    if (k != .m and k != .M) { ts[n] = k; n += 1; }
  }
  break :blk ts[0..n].*;
};

fn makeConcat() type {
  @setEvalBranchQuota(100000);
  const op_default: Op2 = .@",";
  var names: []const []const u8 = &.{ "op" };
  var field_types: []const type = &.{ Op2 };
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (concat_types) |xk| {
    for (concat_types) |yk| {
      const handler: util.DyadFn = getConcatKernel(xk, yk);
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{util.DyadFn};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Concat = makeConcat();

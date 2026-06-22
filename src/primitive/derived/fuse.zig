// Fused reduce-of-zip: `red/ (x bin y)` computed in a single pass without
// materialising the elementwise temp. The optimizer rewrites
// Apply1(red, Apply2(bin, x, y)) -> ReduceZip(red, bin)[x, y].
//
// A fast path covers same-type numeric vectors (I·I, F·F) for the common
// reduce/bin pairs; everything else falls back to the original two-step
// semantics (materialise x bin y, then reduce), so behaviour is unchanged.

const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const dispatch = @import("../dispatch.zig");

// Arithmetic ops whose chains can be fused (they preserve element type, unlike
// comparisons which yield bool mid-chain).
const arith_ops = .{ Op2.@"+", Op2.@"-", Op2.@"*", Op2.@"&", Op2.@"|" };

pub fn reduceZip(vm: *VM, red: Op1, bin: Op2, x: V, y: V) V {
  const xt = x.tag();
  if (xt == y.tag() and (xt == .I or xt == .F) and x.len() == y.len() and x.len() > 0) {
    if (fast(red, bin, x, y)) |r| return r;
  }
  // Fallback: identical to the unfused `red/ (x bin y)`.
  const tmp = dispatch.dispatch2(vm, bin, x, y);
  if (tmp.tag() == .err) return tmp;
  defer tmp.deinit(vm.alloc);
  return dispatch.dispatch1(vm, red, tmp);
}

fn fast(red: Op1, bin: Op2, x: V, y: V) ?V {
  switch (x.tag()) {
    inline .I, .F => |t| {
      const T = comptime if (t == .I) i32 else f32;
      return fastT(T, red, bin, @field(x, @tagName(t)).slice(), @field(y, @tagName(t)).slice());
    },
    else => return null,
  }
}

fn fastT(comptime T: type, red: Op1, bin: Op2, xs: []const T, ys: []const T) ?V {
  inline for (.{ Op1.@"+/", Op1.@"*/", Op1.@"&/", Op1.@"|/" }) |R| {
    if (red == R) {
      inline for (.{ Op2.@"+", Op2.@"-", Op2.@"*", Op2.@"&", Op2.@"|", Op2.@"<", Op2.@">", Op2.@"=" }) |B| {
        if (bin == B) return kernel(T, R, B, xs, ys);
      }
      return null;
    }
  }
  return null;
}

// ── Fused elementwise chain: `(x in y) out z` (side 0) or `z out (x in y)`
// (side 1), computed in one pass without materialising the inner temp. The
// optimizer rewrites Apply2(out, Apply2(in, x, y), z) -> ZipChain(out, in, 0).
//
// Fast path: all three operands same-type numeric vectors (I·I·I, F·F·F) of
// equal length, both ops arithmetic. Anything else falls back to the original
// two-step semantics, so behaviour is unchanged.

// The three operands `s0,s1,s2` arrive in IR-emission (stack) order. `side`
// records the chain shape: side 0 = `(s0 in s1) out s2`, side 1 = `s0 out (s1 in s2)`.
pub fn zipChain(vm: *VM, out: Op2, in: Op2, side: u8, s0: V, s1: V, s2: V) V {
  const t = s0.tag();
  if (t == s1.tag() and t == s2.tag() and (t == .I or t == .F) and
    s0.len() == s1.len() and s1.len() == s2.len() and s0.len() > 0)
  {
    if (chainFast(vm, t, out, in, side, s0, s1, s2)) |r| return r;
  }
  // Fallback: identical to the unfused two-step evaluation.
  if (side == 0) {
    const tmp = dispatch.dispatch2(vm, in, s0, s1);
    if (tmp.tag() == .err) return tmp;
    defer tmp.deinit(vm.alloc);
    return dispatch.dispatch2(vm, out, tmp, s2);
  } else {
    const tmp = dispatch.dispatch2(vm, in, s1, s2);
    if (tmp.tag() == .err) return tmp;
    defer tmp.deinit(vm.alloc);
    return dispatch.dispatch2(vm, out, s0, tmp);
  }
}

fn chainFast(vm: *VM, t: @import("../../noun/class.zig").K, out: Op2, in: Op2, side: u8, x: V, y: V, z: V) ?V {
  switch (t) {
    inline .I, .F => |k| {
      const T = comptime if (k == .I) i32 else f32;
      return chainT(vm, T, out, in, side,
        @field(x, @tagName(k)).slice(), @field(y, @tagName(k)).slice(), @field(z, @tagName(k)).slice());
    },
    else => return null,
  }
}

fn chainT(vm: *VM, comptime T: type, out: Op2, in: Op2, side: u8, xs: []const T, ys: []const T, zs: []const T) ?V {
  inline for (arith_ops) |O| {
    if (out == O) {
      inline for (arith_ops) |I2| {
        if (in == I2) return chainKernel(vm, T, O, I2, side, xs, ys, zs);
      }
      return null;
    }
  }
  return null;
}

fn chainKernel(vm: *VM, comptime T: type, comptime O: Op2, comptime I2: Op2, side: u8, s0: []const T, s1: []const T, s2: []const T) ?V {
  const is_int = comptime T == i32;
  const arr = N(T).init(vm.alloc, s0.len) catch return V{ .err = .memory };
  const rs = arr.slice();
  if (side == 0) { // (s0 in s1) out s2
    for (rs, s0, s1, s2) |*r, a, b, c| r.* = arithf(O, arithf(I2, a, b, is_int), c, is_int);
  } else { // s0 out (s1 in s2)
    for (rs, s0, s1, s2) |*r, a, b, c| r.* = arithf(O, a, arithf(I2, b, c, is_int), is_int);
  }
  return if (is_int) V{ .I = arr } else V{ .F = arr };
}

inline fn isCmp(comptime B: Op2) bool { return B == .@"<" or B == .@">" or B == .@"="; }

fn kernel(comptime T: type, comptime R: Op1, comptime B: Op2, xs: []const T, ys: []const T) ?V {
  const is_int = comptime T == i32;
  if (comptime isCmp(B)) {
    // Comparison intermediate is boolean; reduce it.
    return switch (R) {
      .@"+/" => blk: { // count of true
        var acc: i32 = 0;
        for (xs, ys) |a, b| { if (cmpf(B, a, b)) acc += 1; }
        break :blk V{ .i = acc };
      },
      .@"&/" => blk: { // all
        for (xs, ys) |a, b| { if (!cmpf(B, a, b)) break :blk V{ .b = false }; }
        break :blk V{ .b = true };
      },
      .@"|/" => blk: { // any
        for (xs, ys) |a, b| { if (cmpf(B, a, b)) break :blk V{ .b = true }; }
        break :blk V{ .b = false };
      },
      else => null, // */ over bool not defined by the reducers — fall back
    };
  } else {
    var acc: T = arithf(B, xs[0], ys[0], is_int);
    for (xs[1..], ys[1..]) |a, b| acc = combinef(R, acc, arithf(B, a, b, is_int), is_int);
    return if (is_int) V{ .i = acc } else V{ .f = acc };
  }
}

inline fn cmpf(comptime B: Op2, a: anytype, b: @TypeOf(a)) bool {
  return switch (B) { .@"<" => a < b, .@">" => a > b, .@"=" => a == b, else => unreachable };
}

inline fn arithf(comptime B: Op2, a: anytype, b: @TypeOf(a), comptime is_int: bool) @TypeOf(a) {
  return switch (B) {
    .@"+" => if (is_int) a +% b else a + b,
    .@"-" => if (is_int) a -% b else a - b,
    .@"*" => if (is_int) a *% b else a * b,
    .@"&" => @min(a, b),
    .@"|" => @max(a, b),
    else => unreachable,
  };
}

inline fn combinef(comptime R: Op1, acc: anytype, e: @TypeOf(acc), comptime is_int: bool) @TypeOf(acc) {
  return switch (R) {
    .@"+/" => if (is_int) acc +% e else acc + e,
    .@"*/" => if (is_int) acc *% e else acc * e,
    .@"&/" => @min(acc, e),
    .@"|/" => @max(acc, e),
    else => unreachable,
  };
}

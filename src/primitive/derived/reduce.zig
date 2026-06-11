// Shared SIMD horizontal reductions for the fused derived verbs
// (+/ */ &/ |/). Each routine assumes a non-empty slice; callers handle the
// empty case (which yields .blank).
//
// Integer sum/product use wrapping arithmetic, so vectorised reordering is
// bit-exact with the scalar left fold. min/max are associative+commutative, so
// reordering is exact for both int and float. Float sum/product are NOT
// reassociation-safe and deliberately stay as scalar left folds elsewhere.

const std = @import("std");

inline fn vecLen(comptime T: type) usize {
  return std.simd.suggestVectorLength(T) orelse 1;
}

pub fn sum(comptime T: type, s: []const T) T {
  const is_int = comptime @typeInfo(T) == .int;
  const L = comptime vecLen(T);
  if (comptime L <= 1) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = if (is_int) acc +% v else acc + v;
    return acc;
  }
  if (s.len < L * 2) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = if (is_int) acc +% v else acc + v;
    return acc;
  }
  var vacc: @Vector(L, T) = @splat(0);
  var i: usize = 0;
  while (i + L <= s.len) : (i += L) {
    const chunk: @Vector(L, T) = s[i..][0..L].*;
    vacc = if (is_int) vacc +% chunk else vacc + chunk;
  }
  var acc: T = @reduce(.Add, vacc);
  while (i < s.len) : (i += 1) acc = if (is_int) acc +% s[i] else acc + s[i];
  return acc;
}

pub fn product(comptime T: type, s: []const T) T {
  const is_int = comptime @typeInfo(T) == .int;
  const L = comptime vecLen(T);
  if (comptime L <= 1) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = if (is_int) acc *% v else acc * v;
    return acc;
  }
  if (s.len < L * 2) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = if (is_int) acc *% v else acc * v;
    return acc;
  }
  var vacc: @Vector(L, T) = @splat(1);
  var i: usize = 0;
  while (i + L <= s.len) : (i += L) {
    const chunk: @Vector(L, T) = s[i..][0..L].*;
    vacc = if (is_int) vacc *% chunk else vacc * chunk;
  }
  var acc: T = @reduce(.Mul, vacc);
  while (i < s.len) : (i += 1) acc = if (is_int) acc *% s[i] else acc * s[i];
  return acc;
}

pub fn min(comptime T: type, s: []const T) T {
  const L = comptime vecLen(T);
  if (comptime L <= 1) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = @min(acc, v);
    return acc;
  }
  if (s.len < L * 2) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = @min(acc, v);
    return acc;
  }
  var vacc: @Vector(L, T) = s[0..][0..L].*;
  var i: usize = L;
  while (i + L <= s.len) : (i += L) {
    const chunk: @Vector(L, T) = s[i..][0..L].*;
    vacc = @min(vacc, chunk);
  }
  var acc: T = @reduce(.Min, vacc);
  while (i < s.len) : (i += 1) acc = @min(acc, s[i]);
  return acc;
}

pub fn max(comptime T: type, s: []const T) T {
  const L = comptime vecLen(T);
  if (comptime L <= 1) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = @max(acc, v);
    return acc;
  }
  if (s.len < L * 2) {
    var acc: T = s[0];
    for (s[1..]) |v| acc = @max(acc, v);
    return acc;
  }
  var vacc: @Vector(L, T) = s[0..][0..L].*;
  var i: usize = L;
  while (i + L <= s.len) : (i += L) {
    const chunk: @Vector(L, T) = s[i..][0..L].*;
    vacc = @max(vacc, chunk);
  }
  var acc: T = @reduce(.Max, vacc);
  while (i < s.len) : (i += 1) acc = @max(acc, s[i]);
  return acc;
}

// ── Comptime generators for fused derived verb structs ────────────────────────

const util      = @import("../../util.zig");
const VM        = @import("../../runtime/vm.zig").VM;
const V         = @import("../../noun/value.zig").V;
const Op1       = @import("../../noun/operator.zig").Op1;
const Op2       = @import("../../noun/operator.zig").Op2;
const dispatch  = @import("../dispatch.zig");

// typedFold: I or F monadic reducer using the SIMD helpers above.
pub fn typedFold(comptime T: type, comptime op2: Op2) VM.MonadFn {
  return &struct { fn f(_: *VM, x: V) V {
    const s = if (T == i32) x.I.slice() else x.F.slice();
    if (s.len == 0) return .blank;
    const r = switch (op2) {
      .@"+" => sum(T, s),
      .@"*" => product(T, s),
      .@"&" => min(T, s),
      .@"|" => max(T, s),
      else => unreachable,
    };
    return if (T == i32) V{ .i = r } else V{ .f = r };
  }}.f;
}

// listFold: generic L reducer via dispatch.
pub fn listFold(comptime op2: Op2) VM.MonadFn {
  return &struct { fn f(vm: *VM, x: V) V {
    const n = x.len();
    if (n == 0) return .blank;
    var accum = x.at(0);
    for (1..n) |i| {
      const item = x.at(i);
      defer item.deinit(vm.alloc);
      const next = dispatch.dispatch2(vm, op2, accum, item);
      accum.deinit(vm.alloc);
      accum = next;
    }
    return accum;
  }}.f;
}

// ── Fused derived verb structs ────────────────────────────────────────────────

fn sumB(_: *VM, x: V) V {
  var acc: i32 = 0;
  for (x.B.slice()) |v| if (v) { acc += 1; };
  return .{ .i = acc };
}
fn minB(_: *VM, x: V) V {
  const s = x.B.slice();
  if (s.len == 0) return .blank;
  for (s) |v| if (!v) return .{ .b = false };
  return .{ .b = true };
}
fn maxB(_: *VM, x: V) V {
  const s = x.B.slice();
  if (s.len == 0) return .blank;
  for (s) |v| if (v) return .{ .b = true };
  return .{ .b = false };
}

pub const Sum = struct {
  pub const op = .@"+/";
  _B: VM.MonadFn = sumB,
  _I: VM.MonadFn = typedFold(i32, .@"+"),
  _F: VM.MonadFn = typedFold(f32, .@"+"),
  _L: VM.MonadFn = listFold(.@"+"),
};
pub const Product = struct {
  pub const op = .@"*/";
  _I: VM.MonadFn = typedFold(i32, .@"*"),
  _F: VM.MonadFn = typedFold(f32, .@"*"),
  _L: VM.MonadFn = listFold(.@"*"),
};
pub const Min = struct {
  pub const op = .@"&/";
  _B: VM.MonadFn = minB,
  _I: VM.MonadFn = typedFold(i32, .@"&"),
  _F: VM.MonadFn = typedFold(f32, .@"&"),
  _L: VM.MonadFn = listFold(.@"&"),
};
pub const Max = struct {
  pub const op = .@"|/";
  _B: VM.MonadFn = maxB,
  _I: VM.MonadFn = typedFold(i32, .@"|"),
  _F: VM.MonadFn = typedFold(f32, .@"|"),
  _L: VM.MonadFn = listFold(.@"|"),
};

test "simd reductions match scalar" {
  const ints = [_]i32{ 5, -3, 7, 1, 9, -2, 4, 8, 0, 6, 11, -5, 3, 2, 10, -1, 12 };
  var ssum: i32 = ints[0];
  var smin: i32 = ints[0];
  var smax: i32 = ints[0];
  for (ints[1..]) |v| { ssum +%= v; smin = @min(smin, v); smax = @max(smax, v); }
  try std.testing.expectEqual(ssum, sum(i32, &ints));
  try std.testing.expectEqual(smin, min(i32, &ints));
  try std.testing.expectEqual(smax, max(i32, &ints));
}

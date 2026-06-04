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

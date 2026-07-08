const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;

// True when T is an integer, or a @Vector of integers. The scalar op bodies
// below branch on this to pick wrapping (+%) vs plain arithmetic; without the
// vector case a @Vector(i32) would report .vector and silently take the float
// branch, changing overflow semantics. `pub const simd = {}` marks ops whose
// body is valid on @Vector operands too (used by helper.zig's SIMD kernels).
inline fn eint(comptime T: type) bool {
  const info = @typeInfo(T);
  return info == .int or (info == .vector and @typeInfo(info.vector.child) == .int);
}

pub const AddOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return if (comptime eint(@TypeOf(x))) x +% y else x + y; } };
pub const SubOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return if (comptime eint(@TypeOf(x))) x -% y else x - y; } };
pub const MulOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return if (comptime eint(@TypeOf(x))) x *% y else x * y; } };
pub const DivOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return x / y; } };
pub const DiviOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @divFloor(x, y); } };
pub const ModOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @mod(x, y); } };
pub const MinOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @min(x, y); } };
pub const MaxOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @max(x, y); } };
// `and`/`or` are scalar-only keywords, so the @Vector(bool) form uses @select
// (x?y:x == x and y ; x?x:y == x or y). Identical to the boolean logic per lane.
pub const AndOp = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) {
  return if (comptime @typeInfo(@TypeOf(x)) == .vector) @select(bool, x, y, x) else (x and y);
} };
pub const OrOp  = struct { pub const simd = {}; pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) {
  return if (comptime @typeInfo(@TypeOf(x)) == .vector) @select(bool, x, x, y) else (x or y);
} };

pub const NegOp  = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) {
  if (comptime !eint(@TypeOf(x))) return -x;
  const zero: @TypeOf(x) = if (comptime @typeInfo(@TypeOf(x)) == .vector) @splat(0) else 0;
  return zero -% x;
} };
pub const SqrOp  = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) { return if (comptime eint(@TypeOf(x))) x *% x else x * x; } };
pub const SqrtOp = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) { return @sqrt(x); } };
pub const ExpOp  = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) { return @exp(x); } };
pub const LogOp  = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) { return @log(x); } };
pub const SinOp  = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) { return @sin(x); } };
pub const CosOp  = struct { pub const simd = {}; pub fn f(x: anytype) @TypeOf(x) { return @cos(x); } };
pub const AbsOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return if (@TypeOf(x) == f32) @abs(x) else if (x < 0) 0 -% x else x; } };

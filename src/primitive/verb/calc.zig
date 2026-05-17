const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;

pub const AddOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return if (comptime @typeInfo(@TypeOf(x)) == .int) x +% y else x + y; } };
pub const SubOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return if (comptime @typeInfo(@TypeOf(x)) == .int) x -% y else x - y; } };
pub const MulOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return if (comptime @typeInfo(@TypeOf(x)) == .int) x *% y else x * y; } };
pub const DivOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return x / y; } };
pub const ModOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @mod(x, y); } };
pub const MinOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @min(x, y); } };
pub const MaxOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @max(x, y); } };

pub const NegOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return if (comptime @typeInfo(@TypeOf(x)) == .int) 0 -% x else -x; } };
pub const SqrOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return if (comptime @typeInfo(@TypeOf(x)) == .int) x *% x else x * x; } };
pub const SqrtOp = struct { pub fn f(x: anytype) @TypeOf(x) { return @sqrt(x); } };
pub const ExpOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @exp(x); } };
pub const LogOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @log(x); } };
pub const SinOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @sin(x); } };
pub const CosOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @cos(x); } };
pub const AbsOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return if (@TypeOf(x) == f32) @abs(x) else if (x < 0) 0 -% x else x; } };

const std = @import("std");
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const LessOp  = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x < y; } };
pub const MoreOp  = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x > y; } };
pub const EqualOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x == y; } };

// Not: truthiness negation. Upcast1 converts bool→i32 first,
// so !false and !true work correctly via the i32 branch.
pub const NotOp = struct {
  pub fn f(x: anytype) bool {
    const T = @TypeOf(x);
    if (T == i32) return x == 0;
    if (T == f32) return x == 0.0 or std.math.isNan(x);
    unreachable;
  }
};

const std = @import("std");

pub const FloorOp = struct {
  pub fn f(x: anytype) i32 { return @intFromFloat(std.math.floor(x)); }
};

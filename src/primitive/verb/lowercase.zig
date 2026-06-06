const std = @import("std");
const h = @import("helper.zig");

pub const LowercaseOp = struct {
  pub fn f(x: anytype) u8 { return std.ascii.toLower(@intCast(x)); }
};

pub const Lowercase = h.makeMonad(.@"_", h.Char1, h.Char1, LowercaseOp, &.{.c, .C});

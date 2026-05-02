const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const h = @import("./helper.zig");

pub const LessOp  = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x < y; } };
pub const MoreOp  = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x > y; } };
pub const EqualOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) bool { return x == y; } };

// Not: truthiness negation. Upcast1 converts bool→i32 before the check,
// so !false and !true work correctly via the i32 branch.
pub const NotOp = struct {
  pub fn f(x: anytype) bool {
    const T = @TypeOf(x);
    if (T == i32) return x == 0;
    if (T == f32) return x == 0.0 or std.math.isNan(x);
    unreachable;
  }
};

const at = h.arithmetic_types;

pub const Less  = h.makeDyad(.@"<", h.Upcast2, h.Bool2, LessOp,  &at);
pub const More  = h.makeDyad(.@">", h.Upcast2, h.Bool2, MoreOp,  &at);
pub const Equal = h.makeDyad(.@"=", h.Upcast2, h.Bool2, EqualOp, &at);
pub const Not   = h.makeMonad(.@"~", h.Upcast1, h.Bool1, NotOp,  &at);

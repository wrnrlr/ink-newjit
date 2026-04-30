const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const h = @import("./helper.zig");

const AddOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return x + y; } };
const SubOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return x - y; } };
const MulOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return x * y; } };
const DivOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return x / y; } };
const MinOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @min(x, y); } };
const MaxOp = struct { pub fn f(x: anytype, y: @TypeOf(x)) @TypeOf(x) { return @max(x, y); } };

const NegOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return -x; } };
const SqrOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return x * x; } };
const SqrtOp = struct { pub fn f(x: anytype) @TypeOf(x) { return @sqrt(x); } };
const ExpOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @exp(x); } };
const LogOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @log(x); } };
const SinOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @sin(x); } };
const CosOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return @cos(x); } };
const AbsOp  = struct { pub fn f(x: anytype) @TypeOf(x) { return if (@TypeOf(x) == f32) @abs(x) else if (x < 0) -x else x; } };

const at = h.arithmetic_types;

pub const Add  = h.makeDyad(.@"+", h.Upcast2,      h.Upcast2,      AddOp, &at);
pub const Sub  = h.makeDyad(.@"-", h.Upcast2,      h.Upcast2,      SubOp, &at);
pub const Mul  = h.makeDyad(.@"*", h.Upcast2,      h.Upcast2,      MulOp, &at);
pub const Div  = h.makeDyad(.@"%", h.AlwaysFloat2, h.AlwaysFloat2, DivOp, &at);
pub const Min  = h.makeDyad(.@"&", h.Upcast2,      h.Upcast2,      MinOp, &at);
pub const Max  = h.makeDyad(.@"|", h.Upcast2,      h.Upcast2,      MaxOp, &at);

pub const Neg  = h.makeMonad(.@"-",  h.Upcast1,      h.Upcast1,      NegOp,  &at);
pub const Sqr  = h.makeMonad(.sqr,   h.Upcast1,      h.Upcast1,      SqrOp,  &at);
pub const Sqrt = h.makeMonad(.sqrt,  h.AlwaysFloat1, h.AlwaysFloat1, SqrtOp, &at);
pub const Exp  = h.makeMonad(.exp,   h.AlwaysFloat1, h.AlwaysFloat1, ExpOp,  &at);
pub const Log  = h.makeMonad(.log,   h.AlwaysFloat1, h.AlwaysFloat1, LogOp,  &at);
pub const Sin  = h.makeMonad(.sin,   h.AlwaysFloat1, h.AlwaysFloat1, SinOp,  &at);
pub const Cos  = h.makeMonad(.cos,   h.AlwaysFloat1, h.AlwaysFloat1, CosOp,  &at);
pub const Abs  = h.makeMonad(.abs,   h.Upcast1,      h.Upcast1,      AbsOp,  &at);

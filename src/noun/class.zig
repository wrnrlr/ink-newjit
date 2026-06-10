const std = @import("std");
const assert = std.debug.assert;
const N = @import("value.zig").N;
const Alloc = std.mem.Allocator;

pub const K = enum(u8) {
  blank = 0, err = 1,
  b = 2, i = 3, f = 4, s = 5, c = 6,
  o = 7, p = 8,
  L = 9, m = 10, M = 11, x = 12,
  B = 2  | VEC_BIT, I = 3  | VEC_BIT, F = 4  | VEC_BIT, S = 5  | VEC_BIT, C = 6  | VEC_BIT,

  pub const VEC_BIT: u8       = 16;   // bit 4
  pub const NON_VEC_COUNT: u8 = 13;   // blank(0)..x(12)
  pub const COUNT: usize      = @typeInfo(K).@"enum".fields.len; // 18

  pub inline fn code(k: K) usize {
    const v = @intFromEnum(k);
    if (v & VEC_BIT != 0) return @as(usize, v & ~@as(u8, VEC_BIT)) - 2 + NON_VEC_COUNT;
    return v;
  }

  pub inline fn serCode(k: K) u8 { return @intCast(k.code()); }

  pub fn fromCode(c: u8) ?K {
    return switch (c) {
      0  => .blank,
      1  => .err,
      2  => .b,   3  => .i,   4  => .f,   5  => .s,   6  => .c,
      7  => .o,    8 => .p,       9 => .L, 10 => .m, 11 => .M,
      12 => .x,
      13 => .B,  14 => .I,  15 => .F,  16 => .S,  17 => .C,
      else => null,
    };
  }

  pub fn isScalar(k: K) bool { const v = @intFromEnum(k); return v >= 2 and v <= 6; }
  pub fn isAtom(k: K)   bool { return k.isScalar(); }
  pub fn isVec(k: K)    bool { return @intFromEnum(k) & VEC_BIT != 0; }
  pub fn isNumeric(k: K) bool {
    const e = @intFromEnum(k) & ~@as(u8, VEC_BIT);
    return e >= 2 and e <= 4;
  }
  pub fn isFloat(k: K) bool { return (@intFromEnum(k) & ~@as(u8, VEC_BIT)) == 4; }
  pub fn isMap(k: K) bool { return k == .m or k == .M; }
  pub fn isPlural(k: K) bool { return k.isVec() and k.isMap() and k == .L; } 
  pub inline fn container(comptime k: K) K { return @enumFromInt(@intFromEnum(k) | VEC_BIT); }
  pub inline fn atom(comptime k: K) K { return @enumFromInt(@intFromEnum(k) & ~@as(u8, VEC_BIT)); }

  pub fn backing(comptime k: K) type {
    return switch (k) {
      .blank => void,
      .b, .B => bool,
      .i, .I => i32,
      .f, .F => f32,
      .s, .S => u32,
      .c, .C => u8,
      else => @compileError("no backing type for " ++ @tagName(k)),
    };
  }
  pub fn isNullFn(comptime k: K) fn(K.backing(k)) bool {
    return switch (k) {
      .b, .B => Nulls.b,
      .i, .I => Nulls.i,
      .f, .F => Nulls.f,
      .s, .S => Nulls.s,
      .c, .C => Nulls.c,
      else => struct { fn f(_: usize) bool { return false; } }.f,
    };
  }
  pub const Nulls = struct {
    fn b(_: bool) bool { return false; }
    fn i(v: i32) bool { return v == std.math.minInt(i32); }
    fn f(v: f32) bool { return std.math.isNan(v); }
    fn s(v: u32) bool { return v == 0; }
    fn c(v: u8) bool { return v == ' '; }
  };
};

const std = @import("std");

pub const K = enum(u8) {
  blank = 0, err = 1,
  b = 2, i = 3, f = 4, n = 5, s = 6, c = 7,
  o = 8, p = 9,
  L = 10, m = 11, M = 12, x = 13,
  B = 2  | VEC_BIT, I = 3  | VEC_BIT, F = 4  | VEC_BIT, N = 5  | VEC_BIT, S = 6  | VEC_BIT, C = 7  | VEC_BIT,

  pub const VEC_BIT: u8       = 16;   // bit 4
  pub const NON_VEC_COUNT: u8 = 14;   // blank(0)..x(13)
  pub const COUNT: usize      = @typeInfo(K).@"enum".fields.len; // 20

  pub inline fn serCode(k: K) u8 { return @intCast(k.code()); }
  pub fn isFloat(k: K) bool { return (@intFromEnum(k) & ~@as(u8, VEC_BIT)) == 4; }
  pub fn isMap(k: K) bool { return k == .m or k == .M; }
  pub inline fn container(comptime k: K) K { return @enumFromInt(@intFromEnum(k) | VEC_BIT); }
  pub inline fn atom(comptime k: K) K { return @enumFromInt(@intFromEnum(k) & ~@as(u8, VEC_BIT)); }
  pub fn isAtom(k: K) bool { const v = @intFromEnum(k); return v >= 2 and v <= 7; }
  pub fn isVec(k: K)    bool { return @intFromEnum(k) & VEC_BIT != 0; }

  pub fn isNumeric(k: K) bool {
    const e = @intFromEnum(k) & ~@as(u8, VEC_BIT);
    return e >= 2 and e <= 5;
  }
  pub inline fn code(k: K) usize {
    const v = @intFromEnum(k);
    if (v & VEC_BIT != 0) return @as(usize, v & ~@as(u8, VEC_BIT)) - 2 + NON_VEC_COUNT;
    return v;
  }
  pub fn fromCode(c: u8) ?K {
    return switch (c) {
      0  => .blank, 1  => .err,
      2  => .b, 3 => .i, 4 => .f, 5 => .n, 6 => .s, 7 => .c,
      8  => .o, 9 => .p, 10 => .L, 11 => .m, 12 => .M, 13 => .x,
      14 => .B, 15 => .I, 16 => .F, 17 => .N, 18 => .S, 19 => .C,
      else => null,
    };
  }
  pub fn backing(comptime k: K) type {
    return switch (k) {
      .blank => void,
      .b, .B => bool,
      .i, .I => i32,
      .f, .F => f32,
      .n, .N => u32,
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
      .n, .N => Nulls.n,
      .s, .S => Nulls.s,
      .c, .C => Nulls.c,
      else => struct { fn f(_: usize) bool { return false; } }.f,
    };
  }
  pub const Nulls = struct {
    fn b(_: bool) bool { return false; }
    fn i(v: i32) bool { return v == std.math.minInt(i32); }
    fn f(v: f32) bool { return std.math.isNan(v); }
    fn n(v: u32) bool { return v == std.math.maxInt(u32); }
    fn s(v: u32) bool { return v == 0; }
    fn c(v: u8) bool { return v == ' '; }
  };
};

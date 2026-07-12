const std = @import("std");

pub const K = enum(u8) {
  blank = 0, err = 1,
  b = 2, i = 3, f = 4, n = 5, s = 6, c = 7,
  o = 8, p = 9,
  L = 10, m = 11, M = 12, x = 13,
  // Tier-2 explicit-precision floats (isolated, never implicitly promote):
  //   d = f64 (double), h = f16 (half). Raw values 14/15 fill the last free
  //   non-vec slots under the bit-4 VEC_BIT; adding bf16/fp8 needs a re-layout.
  d = 14, h = 15,
  B = 2  | VEC_BIT, I = 3  | VEC_BIT, F = 4  | VEC_BIT, N = 5  | VEC_BIT, S = 6  | VEC_BIT, C = 7  | VEC_BIT,
  D = 14 | VEC_BIT, H = 15 | VEC_BIT,

  pub const VEC_BIT: u8       = 16;   // bit 4
  pub const NON_VEC_COUNT: u8 = 14;   // blank(0)..x(13); code() offset for the
                                      // original vec types (d/h/D/H are special-cased below)
  pub const COUNT: usize      = @typeInfo(K).@"enum".fields.len; // 24

  pub inline fn serCode(k: K) u8 { return @intCast(k.code()); }
  pub fn isFloat(k: K) bool { return switch (k) { .f, .F, .d, .D, .h, .H => true, else => false }; }
  pub fn isMap(k: K) bool { return k == .m or k == .M; }
  pub inline fn container(comptime k: K) K { return @enumFromInt(@intFromEnum(k) | VEC_BIT); }
  pub inline fn atom(comptime k: K) K { return @enumFromInt(@intFromEnum(k) & ~@as(u8, VEC_BIT)); }
  pub fn isAtom(k: K) bool { return switch (k) { .b, .i, .f, .n, .s, .c, .d, .h => true, else => false }; }
  pub fn isVec(k: K)    bool { return @intFromEnum(k) & VEC_BIT != 0; }

  pub fn isNumeric(k: K) bool {
    return switch (k) { .b, .B, .i, .I, .f, .F, .n, .N, .d, .D, .h, .H => true, else => false };
  }
  pub inline fn code(k: K) usize {
    // d/h/D/H get dense codes appended after the original 0..19 range so
    // serialization (binary.zig via serCode/fromCode) stays stable.
    return switch (k) {
      .d => 20, .h => 21, .D => 22, .H => 23,
      else => {
        const v = @intFromEnum(k);
        if (v & VEC_BIT != 0) return @as(usize, v & ~@as(u8, VEC_BIT)) - 2 + NON_VEC_COUNT;
        return v;
      },
    };
  }
  pub fn fromCode(c: u8) ?K {
    return switch (c) {
      0  => .blank, 1  => .err,
      2  => .b, 3 => .i, 4 => .f, 5 => .n, 6 => .s, 7 => .c,
      8  => .o, 9 => .p, 10 => .L, 11 => .m, 12 => .M, 13 => .x,
      14 => .B, 15 => .I, 16 => .F, 17 => .N, 18 => .S, 19 => .C,
      20 => .d, 21 => .h, 22 => .D, 23 => .H,
      else => null,
    };
  }
  pub fn backing(comptime k: K) type {
    return switch (k) {
      .blank => void,
      .b, .B => bool,
      .i, .I => i32,
      .f, .F => f32,
      .d, .D => f64,
      .h, .H => f16,
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
      .d, .D => Nulls.d,
      .h, .H => Nulls.h,
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
    fn d(v: f64) bool { return std.math.isNan(v); }
    fn h(v: f16) bool { return std.math.isNan(v); }
    fn n(v: u32) bool { return v == std.math.maxInt(u32); }
    fn s(v: u32) bool { return v == 0; }
    fn c(v: u8) bool { return v == ' '; }
  };
};

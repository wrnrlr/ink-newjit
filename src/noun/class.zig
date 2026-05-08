const std = @import("std");
const N = @import("value.zig").N;
const Alloc = std.mem.Allocator;

// Scalars occupy codes 2–6. Vectors are scalar | VEC_BIT (code 2–6 → 18–22).
// This makes container/atom single bitwise ops and type predicates range checks.
//
// Compact sequential dispatch codes (code() → 0–17, dense):
//   blank=0 err=1 b=2 i=3 f=4 s=5 c=6 func=7 partial=8 L=9 m=10 M=11 x=12
//   B=13 I=14 F=15 S=16 C=17
pub const K = enum(u8) {
  blank   = 0,
  err     = 1,
  b       = 2,
  i       = 3,
  f       = 4,
  s       = 5,
  c       = 6,
  func    = 7,
  partial = 8,
  L       = 9,
  m       = 10,
  M       = 11,
  x       = 12,            // extension type (user-defined via ExtVTable)
  B       = 2  | VEC_BIT,  // = 18
  I       = 3  | VEC_BIT,  // = 19
  F       = 4  | VEC_BIT,  // = 20
  S       = 5  | VEC_BIT,  // = 21
  C       = 6  | VEC_BIT,  // = 22

  pub const VEC_BIT: u8       = 16;   // bit 4
  pub const NON_VEC_COUNT: u8 = 13;   // blank(0)..x(12)
  pub const COUNT: usize      = @typeInfo(K).@"enum".fields.len; // 18

  // Compact sequential index for dispatch-table keys (0–17, always dense).
  // Non-vector tags map to themselves (0–12).
  // Vector tags strip VEC_BIT and map into 13–17.
  pub inline fn code(k: K) usize {
    const v = @intFromEnum(k);
    if (v & VEC_BIT != 0) return @as(usize, v & ~@as(u8, VEC_BIT)) - 2 + NON_VEC_COUNT;
    return v;
  }

  // Stable byte for binary serialisation (equals code()).
  pub inline fn serCode(k: K) u8 { return @intCast(k.code()); }

  // Inverse of serCode: compact index → K.  Returns null for unknown codes.
  pub fn fromCode(c: u8) ?K {
    return switch (c) {
      0  => .blank,
      1  => .err,
      2  => .b,   3  => .i,   4  => .f,   5  => .s,   6  => .c,
      7  => .func, 8 => .partial, 9 => .L, 10 => .m, 11 => .M,
      12 => .x,
      13 => .B,  14 => .I,  15 => .F,  16 => .S,  17 => .C,
      else => null,
    };
  }

  pub fn isScalar(k: K) bool { const v = @intFromEnum(k); return v >= 2 and v <= 6; }
  pub fn isAtom(k: K)   bool { return k.isScalar(); }
  pub fn isVec(k: K)    bool { return @intFromEnum(k) & VEC_BIT != 0; }

  // Strip VEC_BIT and test element range (b/B=2, i/I=3, f/F=4).
  pub fn isNumeric(k: K) bool {
    const e = @intFromEnum(k) & ~@as(u8, VEC_BIT);
    return e >= 2 and e <= 4;
  }
  pub fn isInteger(k: K) bool {
    const e = @intFromEnum(k) & ~@as(u8, VEC_BIT);
    return e == 2 or e == 3;
  }
  pub fn isFloat(k: K) bool {
    return (@intFromEnum(k) & ~@as(u8, VEC_BIT)) == 4;
  }
  pub fn isMap(k: K) bool { return k == .m or k == .M; }

  // b → B, i → I, etc.  Caller must ensure k is a scalar type.
  pub inline fn container(comptime k: K) K {
    return @enumFromInt(@intFromEnum(k) | VEC_BIT);
  }
  // B → b, I → i, etc.  Caller must ensure k is a vector type.
  pub inline fn atom(comptime k: K) K {
    return @enumFromInt(@intFromEnum(k) & ~@as(u8, VEC_BIT));
  }

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
  pub fn holder(comptime k: K) type {
    return switch (k) {
      .blank => void,
      .b => bool,  .B => N(bool),
      .i => i32,   .I => N(i32),
      .f => f32,   .F => N(f32),
      .s => u32,   .S => N(u32),
      .c => u8,    .C => N(u8),
      else => @compileError("no holder type for " ++ @tagName(k)),
    };
  }
  pub fn isNullFn(comptime k: K) fn(K.backing(k)) bool {
    return switch (k) {
      .b, .B => struct { fn f(_: bool) bool { return false; } }.f,
      .i, .I => struct { fn f(v: i32) bool { return v == std.math.minInt(i32); } }.f,
      .f, .F => struct { fn f(v: f32) bool { return std.math.isNan(v); } }.f,
      .s, .S => struct { fn f(v: u32) bool { return v == 0; } }.f,
      .c, .C => struct { fn f(v: u8) bool { return v == ' '; } }.f,
      else => struct { fn f(_: usize) bool { return false; } }.f,
    };
  }
};

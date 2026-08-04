const std = @import("std");

// Note: raw value 0 is deliberately unused. `blank` used to live there; null is
// now the identity verb `::` (a plain `.o`), so there is no null *type* at all.
// The remaining raw values are unchanged so the VEC_BIT layout below still holds.
pub const K = enum(u8) {
  err = 1,
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
  pub const COUNT: usize      = @typeInfo(K).@"enum".fields.len; // 23

  // ── Single source of truth ──────────────────────────────────────────────────
  // Every K→element-type / atom↔vector mapping derives from this one table, so
  // adding a numeric type is a single row here (plus a serial_order slot below).
  pub const Backed = struct { atom: K, vec: K, T: type };
  pub const backed = [_]Backed{
    .{ .atom = .b, .vec = .B, .T = bool },
    .{ .atom = .i, .vec = .I, .T = i32 },
    .{ .atom = .f, .vec = .F, .T = f32 },
    .{ .atom = .n, .vec = .N, .T = u32 },
    .{ .atom = .s, .vec = .S, .T = u32 },
    .{ .atom = .c, .vec = .C, .T = u8 },
    .{ .atom = .d, .vec = .D, .T = f64 },
    .{ .atom = .h, .vec = .H, .T = f16 },
  };

  // Stable serialization / dense dispatch-index order. `code()` is the index
  // into this array and `fromCode()` its inverse — kept in sync by construction.
  // Order must not change: it is the on-disk tag encoding (binary.zig) and the
  // key space for the dispatch tables (verbs.zig).
  pub const serial_order = [_]K{
    .err, .b, .i, .f, .n, .s, .c, .o, .p, .L, .m, .M, .x,
    .B, .I, .F, .N, .S, .C, .d, .h, .D, .H,
  };
  const code_table: [32]u8 = blk: {
    var t: [32]u8 = .{0} ** 32;
    for (serial_order, 0..) |sk, i| t[@intFromEnum(sk)] = @intCast(i);
    break :blk t;
  };

  pub inline fn serCode(k: K) u8 { return @intCast(k.code()); }
  pub inline fn container(comptime k: K) K { return @enumFromInt(@intFromEnum(k) | VEC_BIT); }
  pub inline fn atom(comptime k: K) K { return @enumFromInt(@intFromEnum(k) & ~@as(u8, VEC_BIT)); }
  pub fn isAtom(k: K) bool { return switch (k) { .b, .i, .f, .n, .s, .c, .d, .h => true, else => false }; }
  pub fn isVec(k: K)    bool { return @intFromEnum(k) & VEC_BIT != 0; }

  pub inline fn code(k: K) usize { return code_table[@intFromEnum(k)]; }
  pub fn fromCode(c: u8) ?K {
    return if (c < serial_order.len) serial_order[c] else null;
  }
  pub fn backing(comptime k: K) type {
    inline for (backed) |e| if (k == e.atom or k == e.vec) return e.T;
    @compileError("no backing type for " ++ @tagName(k));
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

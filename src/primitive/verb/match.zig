const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
const Op2 = @import("../../noun/operator.zig").Op2;
const h = @import("helper.zig");

const all_k_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len]K = undefined;
  for (fields, 0..) |f, i| ts[i] = @enumFromInt(f.value);
  break :blk ts;
};

pub fn matchFalse(_: *VM, _: V, _: V) V { return .{ .b = false }; }
fn matchBlank  (_: *VM, _: V, _: V) V { return .{ .b = true }; }
fn matchErr    (_: *VM, x: V, y: V) V { return .{ .b = x.err == y.err }; }
fn matchB      (_: *VM, x: V, y: V) V { return .{ .b = x.b == y.b }; }
fn matchI      (_: *VM, x: V, y: V) V { return .{ .b = x.i == y.i }; }
fn matchF      (_: *VM, x: V, y: V) V { return .{ .b = x.f == y.f }; }
fn matchN      (_: *VM, x: V, y: V) V { return .{ .b = x.n == y.n }; }
fn matchD      (_: *VM, x: V, y: V) V { return .{ .b = x.d == y.d }; }
fn matchH      (_: *VM, x: V, y: V) V { return .{ .b = x.h == y.h }; }
fn matchS      (_: *VM, x: V, y: V) V { return .{ .b = x.s == y.s }; }
fn matchC      (_: *VM, x: V, y: V) V { return .{ .b = x.c == y.c }; }
fn matchFunc   (_: *VM, x: V, y: V) V { return .{ .b = @as(u64, @bitCast(x.o)) == @as(u64, @bitCast(y.o)) }; }
fn matchPartial(_: *VM, x: V, y: V) V { return .{ .b = x.p == y.p }; }
fn matchExtObj (_: *VM, x: V, y: V) V { return .{ .b = x.x == y.x }; }

fn matchVec(comptime k: K) VM.Dyad {
  return &struct {
    fn f(_: *VM, x: V, y: V) V {
      const vx = @field(x, @tagName(k));
      const vy = @field(y, @tagName(k));
      if (vx.ptr.len != vy.ptr.len) return .{ .b = false };
      const T = K.backing(k);
      // eqlSimd for the fixed-width numeric backings (std.mem.eql doesn't
      // vectorize them); u8/symbol keep std.mem.eql (memcmp-backed for bytes).
      const eq = if (comptime T == i32 or T == f32 or T == u32 or T == bool)
        eqlSimd(T, vx.slice(), vy.slice())
      else
        std.mem.eql(T, vx.slice(), vy.slice());
      return .{ .b = eq };
    }
  }.f;
}

// SIMD all-equal with a scalar tail. Identical semantics to std.mem.eql: any
// differing lane fails, and f32 NaN lanes report != (two identical-NaN arrays
// are "not equal", as with the scalar `x != y`).
inline fn eqlSimd(comptime T: type, a: []const T, b: []const T) bool {
  const L = 8;
  var i: usize = 0;
  const n = a.len;
  while (i + L <= n) : (i += L) {
    const av: @Vector(L, T) = a[i..][0..L].*;
    const bv: @Vector(L, T) = b[i..][0..L].*;
    if (@reduce(.Or, av != bv)) return false;
  }
  while (i < n) : (i += 1) if (a[i] != b[i]) return false;
  return true;
}

fn matchL(_: *VM, x: V, y: V) V {
  const xs = x.L.slice();
  const ys = y.L.slice();
  if (xs.len != ys.len) return .{ .b = false };
  for (xs, ys) |xv, yv| if (!xv.eq(yv)) return .{ .b = false };
  return .{ .b = true };
}

fn matchDict(comptime k: K) VM.Dyad {
  return &struct {
    fn f(_: *VM, x: V, y: V) V {
      const dx = @field(x, @tagName(k));
      const dy = @field(y, @tagName(k));
      return .{ .b = dx.av().eq(dy.av()) and dx.bv().eq(dy.bv()) };
    }
  }.f;
}

fn getMatchHandler(comptime k: K) VM.Dyad {
  return switch (k) {
    .blank   => &matchBlank,
    .err     => &matchErr,
    .b       => &matchB,
    .i       => &matchI,
    .f       => &matchF,
    .n       => &matchN,
    .d       => &matchD,
    .h       => &matchH,
    .s       => &matchS,
    .c       => &matchC,
    .o    => &matchFunc,
    .p => &matchPartial,
    .x       => &matchExtObj,
    .L       => &matchL,
    .m       => matchDict(.m),
    .M       => matchDict(.M),
    .B       => matchVec(.B),
    .I       => matchVec(.I),
    .F       => matchVec(.F),
    .N       => matchVec(.N),
    .S       => matchVec(.S),
    .C       => matchVec(.C),
    .D       => matchVec(.D),
    .H       => matchVec(.H),
  };
}

fn makeMatch() type {
  @setEvalBranchQuota(1000000);
  const op_default: Op2 = .@"~";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op2};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  // Only the diagonal is registered: mismatched tags hit the stage-2 row
  // fallback, which verbs.zig points at matchFalse for ~.
  for (all_k_types) |xk| {
    const handler: VM.Dyad = getMatchHandler(xk);
    names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(xk)};
    field_types = field_types ++ .{VM.Dyad};
    const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
    attrs = attrs ++ .{attr};
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Match = makeMatch();

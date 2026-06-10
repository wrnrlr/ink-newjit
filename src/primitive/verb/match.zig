const std = @import("std");
const util = @import("../../util.zig");
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

fn matchFalse  (_: *VM, _: V, _: V) V { return .{ .b = false }; }
fn matchBlank  (_: *VM, _: V, _: V) V { return .{ .b = true }; }
fn matchErr    (_: *VM, x: V, y: V) V { return .{ .b = x.err == y.err }; }
fn matchB      (_: *VM, x: V, y: V) V { return .{ .b = x.b == y.b }; }
fn matchI      (_: *VM, x: V, y: V) V { return .{ .b = x.i == y.i }; }
fn matchF      (_: *VM, x: V, y: V) V { return .{ .b = x.f == y.f }; }
fn matchS      (_: *VM, x: V, y: V) V { return .{ .b = x.s == y.s }; }
fn matchC      (_: *VM, x: V, y: V) V { return .{ .b = x.c == y.c }; }
fn matchFunc   (_: *VM, x: V, y: V) V { return .{ .b = @as(u64, @bitCast(x.o)) == @as(u64, @bitCast(y.o)) }; }
fn matchPartial(_: *VM, x: V, y: V) V { return .{ .b = x.p == y.p }; }
fn matchExtObj (_: *VM, x: V, y: V) V { return .{ .b = x.x == y.x }; }

fn matchVec(comptime k: K) util.DyadFn {
  return &struct {
    fn f(_: *VM, x: V, y: V) V {
      const vx = @field(x, @tagName(k));
      const vy = @field(y, @tagName(k));
      if (vx.ptr.len != vy.ptr.len) return .{ .b = false };
      return .{ .b = std.mem.eql(K.backing(k), vx.slice(), vy.slice()) };
    }
  }.f;
}

fn matchL(_: *VM, x: V, y: V) V {
  const xs = x.L.slice();
  const ys = y.L.slice();
  if (xs.len != ys.len) return .{ .b = false };
  for (xs, ys) |xv, yv| if (!xv.eq(yv)) return .{ .b = false };
  return .{ .b = true };
}

fn matchDict(comptime k: K) util.DyadFn {
  return &struct {
    fn f(_: *VM, x: V, y: V) V {
      const dx = @field(x, @tagName(k));
      const dy = @field(y, @tagName(k));
      return .{ .b = dx.av().eq(dy.av()) and dx.bv().eq(dy.bv()) };
    }
  }.f;
}

fn getMatchHandler(comptime k: K) util.DyadFn {
  return switch (k) {
    .blank   => &matchBlank,
    .err     => &matchErr,
    .b       => &matchB,
    .i       => &matchI,
    .f       => &matchF,
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
    .S       => matchVec(.S),
    .C       => matchVec(.C),
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
  for (all_k_types) |xk| {
    for (all_k_types) |yk| {
      const handler: util.DyadFn = if (xk == yk) getMatchHandler(xk) else &matchFalse;
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{util.DyadFn};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Match = makeMatch();

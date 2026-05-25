const std = @import("std");
const util = @import("../../util.zig");
const broadcast = @import("../broadcast.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const Dict = @import("../../noun/dict.zig").Dict;
const K = @import("../../noun/class.zig").K;
const Op = @import("../../runtime/tape.zig").Op;
const h = @import("helper.zig");

// Key types: scalars + typed vecs + generic list.
// Value types: all of the above plus dict (m) and table (M).
const key_types = [_]K{ .b, .i, .f, .s, .c, .B, .I, .F, .S, .C, .L };
const val_types = [_]K{ .b, .i, .f, .s, .c, .B, .I, .F, .S, .C, .L, .m, .M };

fn pairHandler(comptime xk: K, comptime yk: K) util.DyadFn {
  if (xk.isAtom()) return &dictAtomKey;
  if (yk.isAtom()) return &dictVecAtom;
  return &dictVecVec;
}

fn makePair() type {
  @setEvalBranchQuota(100000);
  const op_default: Op = .@"!";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (key_types) |xk| {
    for (val_types) |yk| {
      const handler: util.DyadFn = pairHandler(xk, yk);
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{util.DyadFn};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Pair = makePair();

fn dictAtomKey(vm: *VM, x: V, y: V) V {
  const a2 = x.ref();
  const b2 = y.ref();
  return .{ .m = Dict.init(vm.alloc, a2, b2) catch return V{ .err = .memory } };
}

fn dictVecAtom(vm: *VM, x: V, y: V) V {
  const vals = broadcast.broadcastAtom(vm, y, x.len()) catch return V{ .err = .memory };
  const a2 = x.ref();
  return .{ .m = Dict.init(vm.alloc, a2, vals) catch return V{ .err = .memory } };
}

fn dictVecVec(vm: *VM, x: V, y: V) V {
  if (x.len() != y.len()) return .{ .err = .length };
  const a2 = x.ref();
  const b2 = y.ref();
  return .{ .m = Dict.init(vm.alloc, a2, b2) catch return V{ .err = .memory } };
}

// generic entry point used by external callers (take, drop_keys, vm)
pub fn dict(vm: *VM, x: V, y: V) V {
  if (x.isAtom()) return dictAtomKey(vm, x, y);
  if (y.isAtom()) return dictVecAtom(vm, x, y);
  return dictVecVec(vm, x, y);
}

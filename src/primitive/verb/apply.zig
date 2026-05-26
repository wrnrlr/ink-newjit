const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const Op = @import("../../runtime/tape.zig").Op;
const Call = @import("../../runtime/call.zig").Call;
const syms = @import("../../runtime/syms.zig");
const h = @import("helper.zig");

const pick = @import("pick.zig");

// ---------------------------------------------------------------------------
// Apply1  @ (dyad): func/partial/symbol applied to a single argument
// ---------------------------------------------------------------------------

const all_k_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len]K = undefined;
  for (fields, 0..) |f, i| ts[i] = @enumFromInt(f.value);
  break :blk ts;
};

fn makeApply1() type {
  @setEvalBranchQuota(100000);
  const op_default: Op = .@"@";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  const apply_x_types = [_]K{ .func, .partial, .s };
  for (apply_x_types) |xk| {
    for (all_k_types) |yk| {
      const handler: util.DyadFn = if (xk == .s) &applySymFn else &applyFnFn;
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{util.DyadFn};
      const attr: h.Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub const Apply = makeApply1();

fn applyFnFn(vm: *VM, x: V, y: V) V {
  var fc = Call{ .vm = vm };
  return fc.apply(x, &.{y}, false) catch V{ .err = .memory };
}

fn applySymFn(vm: *VM, x: V, y: V) V {
  return syms.apply(vm, x.s, &.{y}) catch V{ .err = .memory };
}

pub const ApplyN = struct {
  pub const op = .@".";

  _B_b: util.DyadFn = applyAtom,
  _B_i: util.DyadFn = applyAtom,
  _I_b: util.DyadFn = applyAtom,
  _I_i: util.DyadFn = applyAtom,
  _F_b: util.DyadFn = applyAtom,
  _F_i: util.DyadFn = applyAtom,
  _S_b: util.DyadFn = applyAtom,
  _S_i: util.DyadFn = applyAtom,
  _C_b: util.DyadFn = applyAtom,
  _C_i: util.DyadFn = applyAtom,
  _L_b: util.DyadFn = applyAtom,
  _L_i: util.DyadFn = applyAtom,
  
  _m_b: util.DyadFn = applyAtom,
  _m_i: util.DyadFn = applyAtom,
  _m_s: util.DyadFn = applyAtom,

  _B_B: util.DyadFn = dotPath,
  _B_I: util.DyadFn = dotPath,
  _B_S: util.DyadFn = dotPath,
  _B_L: util.DyadFn = dotPath,
  
  _I_B: util.DyadFn = dotPath,
  _I_I: util.DyadFn = dotPath,
  _I_S: util.DyadFn = dotPath,
  _I_L: util.DyadFn = dotPath,
  
  _F_B: util.DyadFn = dotPath,
  _F_I: util.DyadFn = dotPath,
  _F_S: util.DyadFn = dotPath,
  _F_L: util.DyadFn = dotPath,
  
  _S_B: util.DyadFn = dotPath,
  _S_I: util.DyadFn = dotPath,
  _S_S: util.DyadFn = dotPath,
  _S_L: util.DyadFn = dotPath,
  
  _C_B: util.DyadFn = dotPath,
  _C_I: util.DyadFn = dotPath,
  _C_S: util.DyadFn = dotPath,
  _C_L: util.DyadFn = dotPath,
  
  _L_B: util.DyadFn = dotPath,
  _L_I: util.DyadFn = dotPath,
  _L_S: util.DyadFn = dotPath,
  _L_L: util.DyadFn = dotPath,
  
  // _m_B: util.DyadFn = dotPath,
  // _m_I: util.DyadFn = dotPath,
  // _m_S: util.DyadFn = dotPath,
  // _m_L: util.DyadFn = dotPath,
};

fn applyAtom(vm: *VM, x: V, y: V) V {
  const res = x.ref();
  const next = pick.pick(vm.alloc, res, y);
  res.deinit(vm.alloc);
  return next;
}

fn dotPath(vm: *VM, x: V, y: V) V {
  var res = x.ref();
  for (0..y.len()) |i| {
    const idx = y.at(i);
    const next = try pick.pick(vm.alloc, res, idx);
    idx.deinit(vm.alloc);
    res.deinit(vm.alloc);
    if (next.tag() == .err) return next;
    res = next;
  }
  return res;
}

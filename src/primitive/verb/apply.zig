const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;
const K = @import("../../noun/class.zig").K;
const Op2 = @import("../../noun/operator.zig").Op2;
const Call = @import("../../runtime/call.zig").Call;
const syms = @import("../../runtime/syms.zig");
const h = @import("helper.zig");
const pick = @import("pick.zig");

// Apply1  @ (dyad): func/partial/symbol applied to a single argument

const all_k_types = blk: {
  const fields = @typeInfo(K).@"enum".fields;
  var ts: [fields.len]K = undefined;
  for (fields, 0..) |f, i| ts[i] = @enumFromInt(f.value);
  break :blk ts;
};

fn makeApply1() type {
  @setEvalBranchQuota(100000);
  const op_default: Op2 = .@"@";
  var names: []const []const u8 = &.{"op"};
  var field_types: []const type = &.{Op2};
  var attrs: []const h.Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  const apply_x_types = [_]K{ .o, .p, .s };
  for (apply_x_types) |xk| {
    for (all_k_types) |yk| {
      const handler: VM.Dyad = if (xk == .s) &applySymFn else &applyFnFn;
      names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
      field_types = field_types ++ .{VM.Dyad};
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
  return fc.apply(x, &.{y}, false);
}

fn applySymFn(vm: *VM, x: V, y: V) V {
  return syms.apply(vm, x.s, &.{y}) catch V{ .err = .memory };
}

pub const ApplyN = struct {
  pub const op = .@".";

  _B_b: VM.Dyad = applyAtom,
  _B_i: VM.Dyad = applyAtom,
  _I_b: VM.Dyad = applyAtom,
  _I_i: VM.Dyad = applyAtom,
  _F_b: VM.Dyad = applyAtom,
  _F_i: VM.Dyad = applyAtom,
  _S_b: VM.Dyad = applyAtom,
  _S_i: VM.Dyad = applyAtom,
  _C_b: VM.Dyad = applyAtom,
  _C_i: VM.Dyad = applyAtom,
  _L_b: VM.Dyad = applyAtom,
  _L_i: VM.Dyad = applyAtom,
  
  _m_b: VM.Dyad = applyAtom,
  _m_i: VM.Dyad = applyAtom,
  _m_s: VM.Dyad = applyAtom,

  _B_B: VM.Dyad = dotPath,
  _B_I: VM.Dyad = dotPath,
  _B_S: VM.Dyad = dotPath,
  _B_L: VM.Dyad = dotPath,
  
  _I_B: VM.Dyad = dotPath,
  _I_I: VM.Dyad = dotPath,
  _I_S: VM.Dyad = dotPath,
  _I_L: VM.Dyad = dotPath,
  
  _F_B: VM.Dyad = dotPath,
  _F_I: VM.Dyad = dotPath,
  _F_S: VM.Dyad = dotPath,
  _F_L: VM.Dyad = dotPath,
  
  _S_B: VM.Dyad = dotPath,
  _S_I: VM.Dyad = dotPath,
  _S_S: VM.Dyad = dotPath,
  _S_L: VM.Dyad = dotPath,
  
  _C_B: VM.Dyad = dotPath,
  _C_I: VM.Dyad = dotPath,
  _C_S: VM.Dyad = dotPath,
  _C_L: VM.Dyad = dotPath,
  
  _L_B: VM.Dyad = dotPath,
  _L_I: VM.Dyad = dotPath,
  _L_S: VM.Dyad = dotPath,
  _L_L: VM.Dyad = dotPath,
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

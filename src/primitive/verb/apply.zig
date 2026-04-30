const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;

const pick = @import("pick.zig");

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

fn applyAtom(vm: *VM, x: V, y: V) !V {
  const res = x.ref();
  const next = try pick.pick(vm.alloc, res, y);
  res.deinit(vm.alloc);
  return next;
}

fn dotPath(vm: *VM, x: V, y: V) !V {
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

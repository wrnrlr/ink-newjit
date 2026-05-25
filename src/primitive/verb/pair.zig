const std = @import("std");
const value = @import("../../noun/value.zig");
const util = @import("../../util.zig");
const broadcast = @import("../broadcast.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const Alloc = std.mem.Allocator;

pub const Pair = struct {
  pub const op = .@"!";

  // atom key + atom value
  // _b_b: util.DyadFn = dictAtomKey,
  // _b_i: util.DyadFn = dictAtomKey,
  // _b_f: util.DyadFn = dictAtomKey,
  // _b_s: util.DyadFn = dictAtomKey,
  // _b_c: util.DyadFn = dictAtomKey,
  // _i_b: util.DyadFn = dictAtomKey,
  // _i_i: util.DyadFn = dictAtomKey,
  // _i_f: util.DyadFn = dictAtomKey,
  // _i_s: util.DyadFn = dictAtomKey,
  // _i_c: util.DyadFn = dictAtomKey,
  // _f_b: util.DyadFn = dictAtomKey,
  // _f_i: util.DyadFn = dictAtomKey,
  // _f_f: util.DyadFn = dictAtomKey,
  // _f_s: util.DyadFn = dictAtomKey,
  // _f_c: util.DyadFn = dictAtomKey,
  // _s_b: util.DyadFn = dictAtomKey,
  // _s_i: util.DyadFn = dictAtomKey,
  // _s_f: util.DyadFn = dictAtomKey,
  // _s_s: util.DyadFn = dictAtomKey,
  // _s_c: util.DyadFn = dictAtomKey,
  // _c_b: util.DyadFn = dictAtomKey,
  // _c_i: util.DyadFn = dictAtomKey,
  // _c_f: util.DyadFn = dictAtomKey,
  // _c_s: util.DyadFn = dictAtomKey,
  // _c_c: util.DyadFn = dictAtomKey,

  // // atom key + vec value
  // _b_B: util.DyadFn = dictAtomKey,
  // _b_I: util.DyadFn = dictAtomKey,
  // _b_F: util.DyadFn = dictAtomKey,
  // _b_S: util.DyadFn = dictAtomKey,
  // _b_C: util.DyadFn = dictAtomKey,
  // _b_L: util.DyadFn = dictAtomKey,
  // _i_B: util.DyadFn = dictAtomKey,
  // _i_I: util.DyadFn = dictAtomKey,
  // _i_F: util.DyadFn = dictAtomKey,
  // _i_S: util.DyadFn = dictAtomKey,
  // _i_C: util.DyadFn = dictAtomKey,
  // _i_L: util.DyadFn = dictAtomKey,
  // _f_B: util.DyadFn = dictAtomKey,
  // _f_I: util.DyadFn = dictAtomKey,
  // _f_F: util.DyadFn = dictAtomKey,
  // _f_S: util.DyadFn = dictAtomKey,
  // _f_C: util.DyadFn = dictAtomKey,
  // _f_L: util.DyadFn = dictAtomKey,
  // _s_B: util.DyadFn = dictAtomKey,
  // _s_I: util.DyadFn = dictAtomKey,
  // _s_F: util.DyadFn = dictAtomKey,
  // _s_S: util.DyadFn = dictAtomKey,
  // _s_C: util.DyadFn = dictAtomKey,
  // _s_L: util.DyadFn = dictAtomKey,
  // _s_m: util.DyadFn = dictAtomKey,
  // _s_A: util.DyadFn = dictAtomKey,
  // _s_a: util.DyadFn = dictAtomKey,
  // _c_B: util.DyadFn = dictAtomKey,
  // _c_I: util.DyadFn = dictAtomKey,
  // _c_F: util.DyadFn = dictAtomKey,
  // _c_S: util.DyadFn = dictAtomKey,
  // _c_C: util.DyadFn = dictAtomKey,
  // _c_L: util.DyadFn = dictAtomKey,

  // // vec key + atom value (broadcast)
  // _B_b: util.DyadFn = dictVecAtom,
  // _B_i: util.DyadFn = dictVecAtom,
  // _B_f: util.DyadFn = dictVecAtom,
  // _B_s: util.DyadFn = dictVecAtom,
  // _B_c: util.DyadFn = dictVecAtom,
  // _I_b: util.DyadFn = dictVecAtom,
  // _I_i: util.DyadFn = dictVecAtom,
  // _I_f: util.DyadFn = dictVecAtom,
  // _I_s: util.DyadFn = dictVecAtom,
  // _I_c: util.DyadFn = dictVecAtom,
  // _F_b: util.DyadFn = dictVecAtom,
  // _F_i: util.DyadFn = dictVecAtom,
  // _F_f: util.DyadFn = dictVecAtom,
  // _F_s: util.DyadFn = dictVecAtom,
  // _F_c: util.DyadFn = dictVecAtom,
  // _S_b: util.DyadFn = dictVecAtom,
  // _S_i: util.DyadFn = dictVecAtom,
  // _S_f: util.DyadFn = dictVecAtom,
  // _S_s: util.DyadFn = dictVecAtom,
  // _S_c: util.DyadFn = dictVecAtom,
  // _C_b: util.DyadFn = dictVecAtom,
  // _C_i: util.DyadFn = dictVecAtom,
  // _C_f: util.DyadFn = dictVecAtom,
  // _C_s: util.DyadFn = dictVecAtom,
  // _C_c: util.DyadFn = dictVecAtom,

  // // vec key + vec value (zip)
  // _B_B: util.DyadFn = dictVecVec,
  // _B_I: util.DyadFn = dictVecVec,
  // _B_F: util.DyadFn = dictVecVec,
  // _B_S: util.DyadFn = dictVecVec,
  // _B_C: util.DyadFn = dictVecVec,
  // _B_L: util.DyadFn = dictVecVec,
  // _I_B: util.DyadFn = dictVecVec,
  // _I_I: util.DyadFn = dictVecVec,
  // _I_F: util.DyadFn = dictVecVec,
  // _I_S: util.DyadFn = dictVecVec,
  // _I_C: util.DyadFn = dictVecVec,
  // _I_L: util.DyadFn = dictVecVec,
  // _F_B: util.DyadFn = dictVecVec,
  // _F_I: util.DyadFn = dictVecVec,
  // _F_F: util.DyadFn = dictVecVec,
  // _F_S: util.DyadFn = dictVecVec,
  // _F_C: util.DyadFn = dictVecVec,
  // _F_L: util.DyadFn = dictVecVec,
  // _S_B: util.DyadFn = dictVecVec,
  // _S_I: util.DyadFn = dictVecVec,
  // _S_F: util.DyadFn = dictVecVec,
  // _S_S: util.DyadFn = dictVecVec,
  // _S_C: util.DyadFn = dictVecVec,
  // _S_L: util.DyadFn = dictVecVec,
  // _C_B: util.DyadFn = dictVecVec,
  // _C_I: util.DyadFn = dictVecVec,
  // _C_F: util.DyadFn = dictVecVec,
  // _C_S: util.DyadFn = dictVecVec,
  // _C_C: util.DyadFn = dictVecVec,
  // _C_L: util.DyadFn = dictVecVec,
};

// atom key: single-element dict, value is y as-is
fn dictAtomKey(vm: *VM, x: V, y: V) V {
  const a2 = x.ref();
  const b2 = y.ref();
  return .{ .m = Dict.init(vm.alloc, a2, b2) catch return V{ .err = .memory } };
}

// vec/list keys + atom value: broadcast atom to fill all key slots
fn dictVecAtom(vm: *VM, x: V, y: V) V {
  const vals = broadcast.broadcastAtom(vm, y, x.len()) catch return V{ .err = .memory };
  const a2 = x.ref();
  return .{ .m = Dict.init(vm.alloc, a2, vals) catch return V{ .err = .memory } };
}

// vec/list keys + vec/list values: zip (lengths must match)
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

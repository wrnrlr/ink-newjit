const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;

const pick = @import("pick.zig");

pub const Apply1 = struct {
  pub const op = .@"@";

  _B_i: util.DyadFn,
  _B_I: util.DyadFn,
  _I_i: util.DyadFn,
  _I_I: util.DyadFn,
  _F_i: util.DyadFn,
  _F_I: util.DyadFn,
  _C_i: util.DyadFn,
  _C_I: util.DyadFn,
  _S_i: util.DyadFn,
  _S_I: util.DyadFn,
  
  _func_b: util.DyadFn,
  _func_i: util.DyadFn,
  _func_f: util.DyadFn,
  _func_c: util.DyadFn,
  _func_s: util.DyadFn,

  _func_B: util.DyadFn,
  _func_I: util.DyadFn,
  _func_F: util.DyadFn,
  _func_C: util.DyadFn,
  _func_S: util.DyadFn,

  _func_L: util.DyadFn,
  _func_m: util.DyadFn,
  _func_M: util.DyadFn,

  _partial_b: util.DyadFn,
  _partial_i: util.DyadFn,
  _partial_f: util.DyadFn,
  _partial_c: util.DyadFn,
  _partial_s: util.DyadFn,

  _partial_B: util.DyadFn,
  _partial_I: util.DyadFn,
  _partial_F: util.DyadFn,
  _partial_C: util.DyadFn,
  _partial_S: util.DyadFn,

  _partial_L: util.DyadFn,
  _partial_m: util.DyadFn,
  _partial_M: util.DyadFn,
};

const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const Op = @import("../../runtime/tape.zig").Op;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const h = @import("./helper.zig");
const at = h.arithmetic_types;

pub fn _B(op: Op, F: type) type { return h.makeMonad(op, h.Upcast1, h.Bool1, F); }

pub fn _N(comptime op: Op, comptime F: type) type {
  return h.makeMonad(op, h.Upcast1, h.Upcast1, F);
}

pub fn _F(comptime op: Op, comptime F: type) type {
  return h.makeMonad(op, h.Float1, h.Float1, F);
}

pub fn _B_B(comptime op: Op, comptime f: type) type {
  return h.makeDyad(op, h.Bool2, h.Bool2, f, &at);
}

pub fn _N_N(comptime op: Op, comptime f: type) type {
  return h.makeDyad(op, h.Upcast2, h.Upcast2, f, &at);
}

pub fn _F_F(comptime op: Op, comptime f: type) type {
  return h.makeDyad(op, h.Float2, h.Float2, f, &at);
}

fn _A() type {}

fn _A_A() type {}

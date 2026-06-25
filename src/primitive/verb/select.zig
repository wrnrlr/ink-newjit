const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
const Alloc = std.mem.Allocator;
const pair = @import("pair.zig");
const promote = @import("../promote.zig").promote;
const pick = @import("pick.zig");

// ── TakeKeys: x#m → sub-dict with only x's keys ──────────────────────────────

pub const SelectKeys = struct {
  pub const op = .@"#";
  _s_m: VM.Dyad = takeKeys,
  _S_m: VM.Dyad = takeKeys,
  _i_m: VM.Dyad = takeKeys,
  _I_m: VM.Dyad = takeKeys,
  _f_m: VM.Dyad = takeKeys,
  _F_m: VM.Dyad = takeKeys,
  _c_m: VM.Dyad = takeKeys,
  _C_m: VM.Dyad = takeKeys,
  _s_M: VM.Dyad = takeKeysTable,
  _S_M: VM.Dyad = takeKeysTable,
};

pub fn takeKeys(vm: *VM, x: V, y: V) V {
  const xlen = x.len();
  const res_vals = N(V).init(vm.alloc, xlen) catch return V{ .err = .memory };
  const dav = y.m.av();
  const dbv = y.m.bv();
  for (0..xlen) |i| {
    const key = x.at(i);
    defer key.deinit(vm.alloc);
    var found = false;
    for (0..dav.len()) |j| {
      const k = dav.at(j);
      defer k.deinit(vm.alloc);
      if (k.eq(key)) {
        res_vals.slice()[i] = dbv.at(j);
        found = true;
        break;
      }
    }
    if (!found) res_vals.slice()[i] = .{.i=V.@"0N"};
  }
  const res = pair.dict(vm, x, .{ .L = res_vals });
  res_vals.deinit(vm.alloc);
  return res;
}

pub fn takeKeysTable(vm: *VM, x: V, y: V) V {
  const xlen = x.len();
  const res_keys = N(u32).init(vm.alloc, xlen) catch return V{ .err = .memory };
  const res_vals = N(V).init(vm.alloc, xlen) catch {
    res_keys.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  const tav = y.M.av();
  const tbv = y.M.bv();
  for (0..xlen) |i| {
    const key = x.at(i);
    defer key.deinit(vm.alloc);
    const ks: u32 = if (key.tag() == .s) key.s else {
      for (res_vals.slice()[0..i]) |*v| v.deinit(vm.alloc);
      res_keys.deinit(vm.alloc);
      res_vals.deinit(vm.alloc);
      return V{ .err = .@"type" };
    };
    res_keys.slice()[i] = ks;
    var found = false;
    for (0..tav.len()) |j| {
      const k = tav.at(j);
      defer k.deinit(vm.alloc);
      if (k.tag() == .s and k.s == ks) {
        res_vals.slice()[i] = tbv.at(j);
        found = true;
        break;
      }
    }
    if (!found) res_vals.slice()[i] = .blank;
  }
  const dict = Dict.init(vm.alloc, .{ .S = res_keys }, promote(vm.alloc, res_vals)) catch return V{ .err = .memory };
  return V{ .M = dict };
}

// ── SelectDict: m@x → value(s) for key(s) x ─────────────────────────────────

pub const SelectDict = struct {
  pub const op = .@"@";
  _m_s: VM.Dyad = pick.pickDictSymFn,
  _m_S: VM.Dyad = pick.pickDictSymVecFn,
  _m_i: VM.Dyad = pick.pickDictIntFn,
  _m_I: VM.Dyad = pick.pickVecFn,
};

// ── SelectTable: M@x → row(s) by integer index or column(s) by symbol ────────

pub const SelectTable = struct {
  pub const op = .@"@";
  _M_i: VM.Dyad = pick.pickTableRowFn,
  _M_I: VM.Dyad = pick.pickTableRowVecFn,
  _M_s: VM.Dyad = pick.pickTableColFn,
  _M_S: VM.Dyad = pick.pickTableColVecFn,
};

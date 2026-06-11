const std = @import("std");
const Alloc = std.mem.Allocator;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/value.zig").Dict;
const VM = @import("../../runtime/vm.zig").VM;
const pair = @import("pair.zig");
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

/// X_d: drop keys from a dict.
pub const DropKeys = struct {
  pub const op = .@"_";
  _s_m: VM.DyadFn = dropKeys,
  _S_m: VM.DyadFn = dropKeys,
  _i_m: VM.DyadFn = dropKeys,
  _I_m: VM.DyadFn = dropKeys,
  _f_m: VM.DyadFn = dropKeys,
  _F_m: VM.DyadFn = dropKeys,
  _c_m: VM.DyadFn = dropKeys,
  _C_m: VM.DyadFn = dropKeys,
};

pub fn dropKeys(vm: *VM, x: V, y: V) V {
  const dav = y.m.av();
  const dbv = y.m.bv();
  const dict_len = dav.len();
  const xlen = x.len();
  var keep_keys: std.ArrayList(V) = .empty;
  var keep_vals: std.ArrayList(V) = .empty;
  defer { keep_keys.deinit(vm.alloc); keep_vals.deinit(vm.alloc); }
  keep_keys.ensureTotalCapacity(vm.alloc, dict_len) catch return V{ .err = .memory };
  keep_vals.ensureTotalCapacity(vm.alloc, dict_len) catch return V{ .err = .memory };
  for (0..dict_len) |i| {
    const k1 = dav.at(i);
    var found = false;
    for (0..xlen) |j| {
      const xv = x.at(j);
      defer xv.deinit(vm.alloc);
      if (k1.eq(xv)) { found = true; break; }
    }
    if (!found) {
      keep_keys.appendAssumeCapacity(k1);
      keep_vals.appendAssumeCapacity(dbv.at(i));
    } else k1.deinit(vm.alloc);
  }
  const n = keep_keys.items.len;
  // Symbol single-key: pass scalars so the [k:v] formatter shows the value directly (not enlisted)
  if (n == 1 and keep_keys.items[0].tag() == .s) {
    return pair.dict(vm, keep_keys.items[0], keep_vals.items[0]);
  }
  const rk = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(rk.slice(), keep_keys.items);
  const rv = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  @memcpy(rv.slice(), keep_vals.items);
  // n>1: promote keys and vals so e.g. int atoms collapse to a typed vector (1 3 not (1;3))
  // n==1 non-symbol: keep as L so key and val each display as enlisted scalars (,3!,"c")
  const keys_v: V = if (n > 1) promote(vm.alloc, rk) else .{ .L = rk };
  const vals_v: V = if (n > 1) promote(vm.alloc, rv) else .{ .L = rv };
  const res = pair.dict(vm, keys_v, vals_v);
  keys_v.deinit(vm.alloc);
  vals_v.deinit(vm.alloc);
  return res;
}

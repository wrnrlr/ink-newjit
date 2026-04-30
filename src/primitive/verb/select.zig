const std = @import("std");
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const N = @import("../../noun/value.zig").N;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;

const util = @import("../../util.zig");
const pair = @import("pair.zig");

pub const TakeKeys = struct {
  pub const op = .@"#";
  _s_m: util.DyadFn = takeKeys,
  _S_m: util.DyadFn = takeKeys,
  _i_m: util.DyadFn = takeKeys,
  _I_m: util.DyadFn = takeKeys,
  _f_m: util.DyadFn = takeKeys,
  _F_m: util.DyadFn = takeKeys,
  _c_m: util.DyadFn = takeKeys,
  _C_m: util.DyadFn = takeKeys,
};

pub fn takeKeys(vm: *VM, x: V, y: V) !V {
  const xlen = x.len();
  const res_vals = try N(V).init(vm.alloc, xlen);
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
  const res = try pair.dict(vm, x, .{ .L = res_vals });
  res_vals.deinit(vm.alloc);
  return res;
}

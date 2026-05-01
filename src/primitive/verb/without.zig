const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

pub const Without = struct {
  pub const op = .@"^";
  _B_B: util.DyadFn = without,
  _B_I: util.DyadFn = without,
  _B_L: util.DyadFn = without,
  _I_I: util.DyadFn = without,
  _I_F: util.DyadFn = without,
  _I_S: util.DyadFn = without,
  _I_C: util.DyadFn = without,
  _I_B: util.DyadFn = without,
  _I_L: util.DyadFn = without,
  _F_I: util.DyadFn = without,
  _F_F: util.DyadFn = without,
  _F_L: util.DyadFn = without,
  _S_S: util.DyadFn = without,
  _S_L: util.DyadFn = without,
  _C_C: util.DyadFn = without,
  _C_L: util.DyadFn = without,
  _L_I: util.DyadFn = without,
  _L_F: util.DyadFn = without,
  _L_S: util.DyadFn = without,
  _L_C: util.DyadFn = without,
  _L_B: util.DyadFn = without,
  _L_L: util.DyadFn = without,
};

pub fn without(vm: *VM, x: V, y: V) V {
  const ylen = y.len();
  var res_list = std.ArrayList(V).initCapacity(vm.alloc, 0) catch return V{ .err = .memory };
  defer res_list.deinit(vm.alloc);
  for (0..ylen) |i| {
    const val = y.at(i);
    var found = false;
    for (0..x.len()) |j| {
      const xv = x.at(j);
      defer xv.deinit(vm.alloc);
      if (val.eq(xv)) { found = true; break; }
    }
    if (!found) res_list.append(vm.alloc, val) catch return V{ .err = .memory } else val.deinit(vm.alloc);
  }
  const res = N(V).init(vm.alloc, res_list.items.len) catch return V{ .err = .memory };
  @memcpy(res.slice(), res_list.items);
  return promote(vm.alloc, res);
}

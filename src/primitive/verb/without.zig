const std = @import("std");
const Alloc = @import("std").mem.Allocator;
const K = @import("../../noun/class.zig").K;
const N = @import("../../noun/value.zig").N;
const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const promote = @import("../promote.zig").promote;

pub const Without = struct {
  pub const op = .@"^";
  _B_B: util.DyadFn = withoutVec(.B),
  _I_B: util.DyadFn = withoutVec(.B),
  _L_B: util.DyadFn = withoutVec(.B),
  _B_I: util.DyadFn = withoutVec(.I),
  _I_I: util.DyadFn = withoutVec(.I),
  _F_I: util.DyadFn = withoutVec(.I),
  _L_I: util.DyadFn = withoutVec(.I),
  _I_F: util.DyadFn = withoutVec(.F),
  _F_F: util.DyadFn = withoutVec(.F),
  _L_F: util.DyadFn = withoutVec(.F),
  _I_C: util.DyadFn = withoutVec(.C),
  _C_C: util.DyadFn = withoutVec(.C),
  _L_C: util.DyadFn = withoutVec(.C),
  _I_S: util.DyadFn = withoutVec(.S),
  _S_S: util.DyadFn = withoutVec(.S),
  _L_S: util.DyadFn = withoutVec(.S),
  _B_L: util.DyadFn = withoutList,
  _I_L: util.DyadFn = withoutList,
  _F_L: util.DyadFn = withoutList,
  _S_L: util.DyadFn = withoutList,
  _C_L: util.DyadFn = withoutList,
  _L_L: util.DyadFn = withoutList,
};

fn withoutVec(comptime yk: K) util.DyadFn {
  comptime std.debug.assert(yk.isVec());
  return struct {
    const T = K.backing(yk);
    const ak = K.atom(yk);
    fn f(vm: *VM, x: V, y: V) V {
      const src = @field(y, @tagName(yk)).slice();
      var res: std.ArrayList(T) = .empty;
      defer res.deinit(vm.alloc);
      res.ensureTotalCapacity(vm.alloc, src.len) catch return V{ .err = .memory };
      for (src) |elem| {
        const vv: V = @unionInit(V, @tagName(ak), elem);
        var found = false;
        for (0..x.len()) |j| {
          const xv = x.at(j);
          defer xv.deinit(vm.alloc);
          if (vv.eq(xv)) { found = true; break; }
        }
        if (!found) res.appendAssumeCapacity(elem);
      }
      const n = N(T).init(vm.alloc, res.items.len) catch return V{ .err = .memory };
      @memcpy(n.slice(), res.items);
      return V.wrap(yk, n);
    }
  }.f;
}

fn withoutList(vm: *VM, x: V, y: V) V {
  const ylen = y.len();
  var res_list: std.ArrayList(V) = .empty;
  defer res_list.deinit(vm.alloc);
  res_list.ensureTotalCapacity(vm.alloc, ylen) catch return V{ .err = .memory };
  for (0..ylen) |i| {
    const val = y.at(i);
    var found = false;
    for (0..x.len()) |j| {
      const xv = x.at(j);
      defer xv.deinit(vm.alloc);
      if (val.eq(xv)) { found = true; break; }
    }
    if (!found) res_list.appendAssumeCapacity(val) else val.deinit(vm.alloc);
  }
  const res = N(V).init(vm.alloc, res_list.items.len) catch return V{ .err = .memory };
  @memcpy(res.slice(), res_list.items);
  res_list.items.len = 0;
  return promote(vm.alloc, res);
}

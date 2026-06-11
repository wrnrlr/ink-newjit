const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const promote = @import("../promote.zig").promote;

pub const Without = struct {
  pub const op = .@"^";
  _B_B: VM.Dyad = withoutVec(.B),
  _I_B: VM.Dyad = withoutVec(.B),
  _L_B: VM.Dyad = withoutVec(.B),
  _B_I: VM.Dyad = withoutVec(.I),
  _I_I: VM.Dyad = withoutVec(.I),
  _F_I: VM.Dyad = withoutVec(.I),
  _L_I: VM.Dyad = withoutVec(.I),
  _I_F: VM.Dyad = withoutVec(.F),
  _F_F: VM.Dyad = withoutVec(.F),
  _L_F: VM.Dyad = withoutVec(.F),
  _I_C: VM.Dyad = withoutVec(.C),
  _C_C: VM.Dyad = withoutVec(.C),
  _L_C: VM.Dyad = withoutVec(.C),
  _I_S: VM.Dyad = withoutVec(.S),
  _S_S: VM.Dyad = withoutVec(.S),
  _L_S: VM.Dyad = withoutVec(.S),
  _B_L: VM.Dyad = withoutList,
  _I_L: VM.Dyad = withoutList,
  _F_L: VM.Dyad = withoutList,
  _S_L: VM.Dyad = withoutList,
  _C_L: VM.Dyad = withoutList,
  _L_L: VM.Dyad = withoutList,
};

fn withoutVec(comptime yk: K) VM.Dyad {
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

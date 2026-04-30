const std = @import("std");
const value = @import("../../noun/value.zig");
const pair = @import("pair.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const N = @import("../../noun/value.zig").N;
const V = value.V;
const Dict = value.Dict;
const Table = value.Table;
const UTable = value.UTable;
const Alloc = std.mem.Allocator;

pub const DictMerge = struct {
  pub const op = .@",";
  _m_m: util.DyadFn = merge,
};

fn merge(vm: *VM, x: V, y: V) !V {
  var keys = try std.ArrayList(V).initCapacity(vm.alloc, 0);
  var vals = try std.ArrayList(V).initCapacity(vm.alloc, 0);
  defer { keys.deinit(vm.alloc); vals.deinit(vm.alloc); }
  const d1k = x.m.av();
  const d1v = x.m.bv();
  for (0..d1k.len()) |i| {
    try keys.append(vm.alloc, d1k.at(i));
    try vals.append(vm.alloc, d1v.at(i));
  }
  const d2k = y.m.av();
  const d2v = y.m.bv();
  for (0..d2k.len()) |i| {
    const k2 = d2k.at(i);
    var found = false;
    for (keys.items, 0..) |k1, j| {
      if (k1.eq(k2)) {
        vals.items[j].deinit(vm.alloc);
        vals.items[j] = d2v.at(i);
        k2.deinit(vm.alloc);
        found = true;
        break;
      }
    }
    if (!found) {
      try keys.append(vm.alloc, k2);
      try vals.append(vm.alloc, d2v.at(i));
    }
  }
  const rk = try N(V).init(vm.alloc, keys.items.len);
  @memcpy(rk.slice(), keys.items);
  const rv = try N(V).init(vm.alloc, vals.items.len);
  @memcpy(rv.slice(), vals.items);
  const res = try pair.dict(vm, .{ .L = rk }, .{ .L = rv });
  rk.deinit(vm.alloc);
  rv.deinit(vm.alloc);
  return res;
}

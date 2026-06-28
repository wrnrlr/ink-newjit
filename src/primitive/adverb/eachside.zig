const std = @import("std");
const Alloc = std.mem.Allocator;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const promote = @import("../promote.zig").promote;

pub fn eachright(vm: *VM, base: V, x: V, y: V, f: util.ApplyFn) V {
  const n = y.len();
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  // bump rc so the in-place mutation opt in dyadKernel never fires on the shared left arg
  const xr = x.ref();
  defer xr.deinit(vm.alloc);
  for (0..n) |i| {
    const item = y.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ xr, item };
    res.slice()[i] = f(vm, base, &args);
  }
  return promote(vm.alloc, res);
}

pub fn eachleft(vm: *VM, base: V, x: V, y: V, f: util.ApplyFn) V {
  const n = x.len();
  var res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
  // bump rc so the in-place mutation opt in dyadKernel never fires on the shared right arg
  const yr = y.ref();
  defer yr.deinit(vm.alloc);
  for (0..n) |i| {
    const item = x.at(i);
    defer item.deinit(vm.alloc);
    const args = [_]V{ item, yr };
    res.slice()[i] = f(vm, base, &args);
  }
  return promote(vm.alloc, res);
}

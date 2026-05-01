const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const value = @import("../../noun/value.zig");
const format = @import("../../noun/format.zig");
const util = @import("../../util.zig");
const V = value.V;

pub const Open = struct {
  pub const op = .@"<";

  _s: util.MonadFn = open,
};

fn open(vm: *VM, x: V) V {
  const path = vm.getSymbol(x.s);
  const id = vm.mapFile(path) catch return V{ .err = .io };
  return V{ .i = @intCast(id) };
}

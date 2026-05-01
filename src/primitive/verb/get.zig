const std = @import("std");
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = value.V;

pub const GetSymbol = struct {
  pub const op = .@".";
  _s: util.MonadFn = getSymbol,
  _C: util.MonadFn = parseString,
};

fn getSymbol(vm: *VM, x: V) V {
  const sname = vm.getSymbol(x.s);
  if (vm.globals_names.get(sname)) |idx| {
    if (idx < vm.globals.items.len) return vm.globals.items[idx].ref();
  }
  return V{ .err = .domain };
}

fn parseString(_: *VM, x: V) V {
  const s = std.mem.trim(u8, x.C.slice(), &[_]u8{ ' ', '\t', '\r', '\n' });
  if (std.fmt.parseInt(i32, s, 10)) |iv| return .{ .i = iv } else |_| {}
  if (std.fmt.parseFloat(f32, s)) |fv| return .{ .f = fv } else |_| {}
  return V{ .err = .domain };
}

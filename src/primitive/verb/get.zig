const std = @import("std");
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const GetSymbol = struct {
  pub const op = .@".";
  _s: util.MonadFn = getSymbol,
  _C: util.MonadFn = parseString,
};

fn getSymbol(vm: *VM, x: V) V {
  const sname = vm.getSymbol(x.s);
  if (vm.names.get(sname)) |idx| {
    return vm.globals[idx].ref();
  }
  return V{ .err = .domain };
}

fn parseString(_: *VM, x: V) V {
  const s = std.mem.trim(u8, x.C.slice(), &[_]u8{ ' ', '\t', '\r', '\n' });
  if (std.fmt.parseInt(i32, s, 10)) |iv| return .{ .i = iv } else |_| {}
  if (std.fmt.parseFloat(f32, s)) |fv| return .{ .f = fv } else |_| {}
  return V{ .err = .domain };
}

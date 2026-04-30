const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const V = value.V;

pub const GetSymbol = struct {
  pub const op = .@".";
  _s: util.MonadFn = getSymbol,
};

fn getSymbol(vm: *VM, x: V) !V {
  const sname = vm.getSymbol(x.s);
  if (vm.globals_names.get(sname)) |idx| {
    if (idx < vm.globals.items.len) return vm.globals.items[idx].ref();
  }
  return V{ .err = .domain };
}

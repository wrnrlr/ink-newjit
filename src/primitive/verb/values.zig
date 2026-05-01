const std = @import("std");
const value = @import("../../noun/value.zig");
const calc = @import("./calc.zig");
const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const N = @import("../../noun/value.zig").N;
const V = value.V;
const Dict = value.Dict;
const Alloc = std.mem.Allocator;

pub const GetSymbol = struct {
  pub const op = .@".";
  _s: util.MonadFn = get_symbol,
};

fn get_symbol(vm: *VM, x: V) V {
  const sname = vm.getSymbol(x.s);
  if (vm.globals_names.get(sname)) |idx| {
    // assert (idx < vm.globals.items.len)
    return vm.globals.items[idx].ref();
  }
  return V{ .err = .domain };
}

pub const Values = struct {
  pub const op = .@".";
  _m: util.MonadFn = values_dict
  // pub fn _A(vm: *VM, x: V) V { _ = vm; return x.A.bv().retain(); }
  // pub fn _a(vm: *VM, x: V) V { _ = vm; return x.a.bv().retain(); }
};

fn values_dict(vm: *VM, x: V) V { _ = vm; return x.m.bv().ref(); }

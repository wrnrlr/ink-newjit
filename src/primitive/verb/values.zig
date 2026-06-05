const util = @import("../../util.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;

pub const Values = struct {
  pub const op = .@".";
  _m: util.MonadFn = values_dict,
};

fn values_dict(_: *VM, x: V) V { return x.m.bv().ref(); }

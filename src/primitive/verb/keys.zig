const V = @import("../../noun/value.zig").V;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Keys = struct {
  pub const op = .@"!";
  _m: util.MonadFn = keysDict,
  _M: util.MonadFn = keysTable,
};

fn keysDict(_: *VM, x: V) V { return x.m.av().ref(); }
fn keysTable(_: *VM, x: V) V { return x.M.av().ref(); }

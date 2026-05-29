const Op1 = @import("../noun/operator.zig").Op1;
const Op2 = @import("../noun/operator.zig").Op2;
const verbs = @import("verb/verbs.zig");
const VM = @import("../runtime/vm.zig").VM;
const K = @import("../noun/class.zig").K;
const V = @import("../noun/value.zig").V;

pub fn dispatch1(vm: *VM, op: Op1, x: V) V {
  const xt = x.tag();
  const key = op.code() * K.COUNT + xt.code();
  return verbs.monad_table[key](vm, x);
}

pub fn dispatch2(vm: *VM, op: Op2, x: V, y: V) V {
  const xt = x.tag();
  const yt = y.tag();
  const key = op.code() * K.COUNT * K.COUNT + xt.code() * K.COUNT + yt.code();
  return verbs.dyad_table[key](vm, x, y);
}

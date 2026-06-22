const Op1 = @import("../noun/operator.zig").Op1;
const Op2 = @import("../noun/operator.zig").Op2;
const Op3 = @import("../noun/operator.zig").Op3;
const Op4 = @import("../noun/operator.zig").Op4;
const verbs = @import("verb/verbs.zig");
const amend = @import("amend.zig");
const splice = @import("verb/splice.zig");
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

/// Type-specialized dispatch: call a dispatch-table slot by precomputed key,
/// skipping the tag-read + key arithmetic. The caller (typed Apply opcodes) is
/// responsible for verifying the operand classes match `key` first.
pub fn dispatch1At(vm: *VM, key: usize, x: V) V {
  return verbs.monad_table[key](vm, x);
}
pub fn dispatch2At(vm: *VM, key: usize, x: V, y: V) V {
  return verbs.dyad_table[key](vm, x, y);
}

pub fn dispatch3(vm: *VM, op: Op3, x: V, y: V, z: V) V {
  var args = [_]V{ x, y, z };
  return switch (op) {
    .amend3 => amend.amend(vm, &args),
    .drill3 => amend.dmend(vm, &args),
    .splice3 => splice.splice(vm, x, y, z),
  };
}

pub fn dispatch4(vm: *VM, op: Op4, x: V, y: V, z: V, w: V) V {
  var args = [_]V{ x, y, z, w };
  return switch (op) {
    .amend4 => amend.amend(vm, &args),
    .drill4 => amend.dmend(vm, &args),
  };
}

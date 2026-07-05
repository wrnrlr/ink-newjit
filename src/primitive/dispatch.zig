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
  const oc = op.code();
  if (oc < Op2.QUICK_COUNT) {
    // Stage 1: dense shift-indexed table over the numeric types. Container
    // and exotic operands map to the sentinel code, whose slot holds the
    // per-op structural fallback (dict recursion / list broadcast / error).
    const key = (oc << 8) | (@as(usize, verbs.stage1code[xt.code()]) << 4) | verbs.stage1code[yt.code()];
    return verbs.quick_table[key](vm, x, y);
  }
  // Stage 2: binary-search the op's sparse sorted row; a miss hits the op's
  // fallback (container broadcast for = | & < > mod div, else type error).
  const row = oc - Op2.QUICK_COUNT;
  const key: u16 = @intCast(xt.code() * K.COUNT + yt.code());
  var lo: usize = verbs.stage2off[row];
  var hi: usize = verbs.stage2off[row + 1];
  while (lo < hi) {
    const mid = (lo + hi) / 2;
    const k = verbs.stage2keys[mid];
    if (k == key) return verbs.stage2fns[mid](vm, x, y);
    if (k < key) lo = mid + 1 else hi = mid;
  }
  return verbs.stage2fb[row](vm, x, y);
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

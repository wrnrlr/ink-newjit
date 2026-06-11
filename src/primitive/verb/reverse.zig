const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Reverse = struct {
  pub const op = .@"|";
  _B: VM.MonadFn = reverse(.B),
  _I: VM.MonadFn = reverse(.I),
  _F: VM.MonadFn = reverse(.F),
  _S: VM.MonadFn = reverse(.S),
  _C: VM.MonadFn = reverse(.C),
  _L: VM.MonadFn = reverseList,
};

fn reverseList(vm: *VM, x: V) V {
  const src = x.L.slice();
  const res = N(V).init(vm.alloc, src.len) catch return V{ .err = .memory };
  for (src, 0..) |v, i| res.slice()[src.len - 1 - i] = v.ref();
  return .{ .L = res };
}

fn reverse(comptime yk: K) VM.MonadFn {
  return struct {
    fn f(vm: *VM, x: V) V {
      const T = K.backing(yk);
      const b = @field(x, @tagName(yk));
      const res = N(T).init(vm.alloc, b.ptr.len) catch return V{ .err = .memory };
      const src = b.slice();
      const dst = res.slice();
      for (src, 0..) |v, i| dst[src.len - 1 - i] = if (yk == .L) v.ref() else v;
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}

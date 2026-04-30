const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/value.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");

pub const Reverse = struct {
  pub const op = .@"|";
  _B: util.MonadFn = reverse(.B),
  _I: util.MonadFn = reverse(.I),
  _F: util.MonadFn = reverse(.F),
  _S: util.MonadFn = reverse(.S),
  _C: util.MonadFn = reverse(.C),
  // _L: util.MonadFn = reverse(.L), // TODO fix L
};

fn reverse(comptime yk: K) util.MonadFn {
  return struct {
    fn f(vm: *VM, x: V) !V {
      const T = K.backing(yk);
      const b = @field(x, @tagName(yk));
      const res = try N(T).init(vm.alloc, b.ptr.len);
      const src = b.slice();
      const dst = res.slice();
      for (src, 0..) |v, i| dst[src.len - 1 - i] = if (yk == .L) v.ref() else v;
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}

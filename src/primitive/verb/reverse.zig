const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

pub const Reverse = struct {
  pub const op = .@"|";
  _B: VM.Monad = reverse(.B),
  _I: VM.Monad = reverse(.I),
  _F: VM.Monad = reverse(.F),
  _N: VM.Monad = reverse(.N),
  _D: VM.Monad = reverse(.D),
  _H: VM.Monad = reverse(.H),
  _S: VM.Monad = reverse(.S),
  _C: VM.Monad = reverse(.C),
  _L: VM.Monad = reverseList,
};

fn reverseList(vm: *VM, x: V) V {
  const src = x.L.slice();
  const res = N(V).init(vm.alloc, src.len) catch return V{ .err = .memory };
  for (src, 0..) |v, i| res.slice()[src.len - 1 - i] = v.ref();
  return .{ .L = res };
}

fn reverse(comptime yk: K) VM.Monad {
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

const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const h = @import("helper.zig");

pub const Reverse = h._G(.@"|", &.{ .B, .I, .F, .N, .D, .H, .S, .C, .L }, reverse);

fn reverse(comptime yk: K) VM.Monad {
  const T = comptime if (yk == .L) V else K.backing(yk);
  return struct {
    fn f(vm: *VM, x: V) V {
      const b = @field(x, @tagName(yk));
      const res = N(T).init(vm.alloc, b.ptr.len) catch return V{ .err = .memory };
      const src = b.slice();
      const dst = res.slice();
      for (src, 0..) |v, i| dst[src.len - 1 - i] = if (yk == .L) v.ref() else v;
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}

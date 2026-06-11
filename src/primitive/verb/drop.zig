const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;

pub const Drop = struct {
  pub const op = .@"_";
  _i_B: VM.Dyad = drop(.B),
  _i_I: VM.Dyad = drop(.I),
  _i_F: VM.Dyad = drop(.F),
  _i_S: VM.Dyad = drop(.S),
  _i_C: VM.Dyad = drop(.C),
  _i_L: VM.Dyad = drop(.L),
};

fn drop(comptime yk: K) VM.Dyad {
  const T = comptime if (yk == .L) V else K.backing(yk);
  return struct {
    fn f(vm: *VM, x: V, y: V) V {
      const arr = @field(y, @tagName(yk));
      const old_len = arr.ptr.len;
      const n: usize = @intCast(@abs(x.i));
      const new_len = if (n >= old_len) 0 else old_len - n;
      const start: usize = if (x.i > 0) old_len - new_len else 0;
      const res = N(T).init(vm.alloc, new_len) catch return V{ .err = .memory };
      const src = arr.slice()[start .. start + new_len];
      if (comptime yk == .L) {
        for (res.slice(), src) |*dst, s| dst.* = s.ref();
      } else {
        @memcpy(res.slice(), src);
      }
      return @unionInit(V, @tagName(yk), res);
    }
  }.f;
}

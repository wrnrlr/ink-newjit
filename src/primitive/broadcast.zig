const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const Alloc = std.mem.Allocator;
const assert = std.debug.assert;
const K = @import("../noun/class.zig").K;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;

pub fn broadcastAtom(vm: *VM, x: V, n: usize) !V {
  assert(x.isAtom());
  switch (x) {
    inline .b, .i, .f, .s, .c => |val, kt| {
      const T = comptime K.backing(kt);
      const vec = try N(T).init(vm.alloc, n);
      @memset(vec.slice(), val);
      return @unionInit(V, @tagName(kt.container()), vec);
    },
    else => unreachable,
  }
}

// Maybe there should be a splat function on N
pub fn Broadcast(comptime k: K, alloc: Alloc, n: usize, v: k.backing()) !N(k.backing())  {
  const vec = try N(k.backing()).init(alloc, n);
  @memset(vec.slice(), v);
  return vec;
}

const std = @import("std");
const VM = @import("../runtime/vm.zig").VM;
const Alloc = std.mem.Allocator;
const assert = std.debug.assert;
const K = @import("../noun/class.zig").K;
const V = @import("../noun/value.zig").V;
const N = @import("../noun/array.zig").N;

// Maybe there should be a splat function on N
// pub fn Broadcast(comptime k: K, alloc: Alloc, n: usize, v: k.backing()) !N(k.backing())  {
//   const vec = try N(k.backing()).init(alloc, n);
//   @memset(vec.slice(), v);
//   return vec;
// }

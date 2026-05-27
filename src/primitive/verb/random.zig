const std = @import("std");
const util = @import("../../util.zig");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const N = @import("../../noun/array.zig").N;
const VM = @import("../../runtime/vm.zig").VM;
const promote = @import("../promote.zig").promote;

pub const Random = struct {
  pub const op = .@"?";
  _i_I: util.DyadFn = randomVec(.I),
  _i_F: util.DyadFn = randomVec(.F),
  _i_S: util.DyadFn = randomVec(.S),
  _i_C: util.DyadFn = randomVec(.C),
  _i_B: util.DyadFn = randomVec(.B),
  _i_L: util.DyadFn = randomList,
};

// fastrange32: equivalent to ngn/k's ri(m) = (uint32_t)r()*m>>32.
// Avoids the 128-bit mulWide used by uintLessThan(usize, n).
// Slightly biased but constant-time and ~2x faster on aarch64.
inline fn randBelow(prng: *std.Random.DefaultPrng, n: usize) usize {
  return @intCast(@as(u64, @as(u32, @truncate(prng.next()))) * @as(u64, n) >> 32);
}

fn randomVec(comptime yk: K) util.DyadFn {
  comptime std.debug.assert(yk.isVec());
  return struct {
    const T = K.backing(yk);
    fn f(vm: *VM, x: V, y: V) V {
      const src = @field(y, @tagName(yk)).slice();
      const n = src.len;
      const count: usize = @intCast(@abs(x.i));
      if (x.i >= 0) {
        if (n == 0) return .{ .err = .length };
        const res = N(T).init(vm.alloc, count) catch return V{ .err = .memory };
        for (res.slice()) |*v| v.* = src[randBelow(&vm.prng, n)];
        return V.wrap(yk, res);
      } else {
        if (count > n) return .{ .err = .length };
        var indices = vm.alloc.alloc(usize, n) catch return V{ .err = .memory };
        defer vm.alloc.free(indices);
        for (indices, 0..) |*idx, j| idx.* = j;
        for (0..count) |j| {
          const swap_idx = j + randBelow(&vm.prng, n - j);
          const tmp = indices[j];
          indices[j] = indices[swap_idx];
          indices[swap_idx] = tmp;
        }
        const res = N(T).init(vm.alloc, count) catch return V{ .err = .memory };
        for (res.slice(), 0..) |*v, j| v.* = src[indices[j]];
        return V.wrap(yk, res);
      }
    }
  }.f;
}

fn randomList(vm: *VM, x: V, y: V) V {
  const n = y.len();
  const count: usize = @intCast(@abs(x.i));
  if (x.i >= 0) {
    if (n == 0) return .{ .err = .length };
    const res = N(V).init(vm.alloc, count) catch return V{ .err = .memory };
    for (res.slice()) |*val| val.* = y.at(randBelow(&vm.prng, n));
    return promote(vm.alloc, res);
  } else {
    if (count > n) return .{ .err = .length };
    var indices = vm.alloc.alloc(usize, n) catch return V{ .err = .memory };
    defer vm.alloc.free(indices);
    for (indices, 0..) |*idx, j| idx.* = j;
    for (0..count) |j| {
      const swap_idx = j + randBelow(&vm.prng, n - j);
      const tmp = indices[j];
      indices[j] = indices[swap_idx];
      indices[swap_idx] = tmp;
    }
    const res = N(V).init(vm.alloc, count) catch return V{ .err = .memory };
    for (res.slice(), 0..) |*v, j| v.* = y.at(indices[j]);
    return promote(vm.alloc, res);
  }
}

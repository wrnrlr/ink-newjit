const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../noun/value.zig");
const VM = @import("../runtime/vm.zig").VM;
const V = value.V;
const Adverb = @import("../noun/operator.zig").Adverb;
const util = @import("../util.zig");
const adverbs = @import("adverb/adverbs.zig");

pub fn derived(vm: *VM, base: V, adv: Adverb, args: []const V, f: util.ApplyFn) V {
  // Stencil: f'[n;x] — integer n means window size, not each2 broadcast.
  if (adv == .@"'" and args.len == 2 and args[0].tag() == .i
      and base.tag() == .func and base.func.getRealArity() == 1)
    return adverbs.stencil(vm, args[0], base, args[1], f);
  // Multi-arg each: f'[x;y;...] → apply base element-wise across tuples.
  if (adv == .@"'" and args.len >= 2)
    return adverbs.zip(vm, base, args, f);

  if (args.len == 1) return derived2(vm, adv, base, args[0], f);
  if (args.len == 2) return derived3(vm, adv, base, args[0], args[1], f);
  // N>2 args for non-each adverbs: pass through to base function directly.
  return f(vm, base, args);
}

fn derived2(vm: *VM, adv: Adverb, x: V, y: V, f: util.ApplyFn) V {
  const xt = x.tag();
  const base_is_radix = xt == .I or xt == .i or xt == .b;
  const base_is_char  = xt == .c or xt == .C;
  return switch (adv) {
    .@"'" => if (xt == .i) adverbs.window(vm, x, y) else adverbs.each(vm, x, y, f),
    .@"/" => blk: {
      if (base_is_radix) break :blk adverbs.decode(vm, x, y);
      if (base_is_char)  break :blk adverbs.join(vm, x, y);
      if (x.arity() == 1) break :blk adverbs.converge(vm, x, y, f);
      break :blk adverbs.fold(vm, x, null, y, f);
    },
    .@"\\" => blk: {
      if (base_is_radix) break :blk adverbs.encode(vm, x, y);
      if (base_is_char)  break :blk adverbs.split(vm, x, y);
      if (x.arity() == 1) break :blk adverbs.converges(vm, x, y, f);
      break :blk adverbs.scan(vm, x, null, y, f);
    },
    .@"':" => if (xt == .i) adverbs.window(vm, x, y) else adverbs.eachprior(vm, x, null, y, f),
    .@"/:", .@"\\:" => V{ .err = .rank }, // require a 2nd data arg
  };
}

fn derived3(vm: *VM, adv: Adverb, x: V, y: V, z: V, f: util.ApplyFn) V {
  return switch (adv) {
    .@"'" => .{ .err = .nyi },
    .@"/" => blk: {
      if (y.tag() == .i and x.arity() == 1) break :blk adverbs.ndo(vm, x, y.i, z, f);
      if ((y.tag() == .func or y.tag() == .partial) and x.arity() >= 1)
        break :blk adverbs.whiledo(vm, y, x, z, f);
      break :blk adverbs.fold(vm, x, y, z, f);
    },
    .@"\\" => blk: {
      if (y.tag() == .i and x.arity() == 1) break :blk adverbs.ndos(vm, x, y.i, z, f);
      if ((y.tag() == .func or y.tag() == .partial) and x.arity() >= 1)
        break :blk adverbs.whilescan(vm, y, x, z, f);
      break :blk adverbs.scan(vm, x, y, z, f);
    },
    .@"':"  => adverbs.eachprior(vm, x, y, z, f),
    .@"/:"  => adverbs.eachright(vm, x, y, z, f),
    .@"\\:" => adverbs.eachleft(vm, x, y, z, f),
  };
}

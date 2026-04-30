const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Adverb = value.Adverb;

// pub const converge = @import("converge.zig").converge;
// pub const converges = @import("converges.zig").converges;
const decode = @import("decode.zig").decode;
const each1 = @import("each1.zig").each1;
const each2 = @import("each2.zig").each2;
const eachleft = @import("eachleft.zig").eachleft;
const eachprior = @import("eachprior.zig").eachprior;
const eachright = @import("eachright.zig").eachright;
const encode = @import("encode.zig").encode;
const fold = @import("fold.zig").fold;
const join = @import("join.zig").join;
const scan = @import("scan.zig").scan;
const split = @import("split.zig").split;
const stencil = @import("stencil.zig").stencil;
const window = @import("window.zig").window;

pub fn derived(vm: *VM, base: V, adv: Adverb, args: []const V, f: anytype) !V {
  // Multi-arg each: f'[x;y;...] → apply base to element-wise tuples
  if (adv == .@"'" and args.len >= 2)
    return try each2(vm, base, args, f);
  if (args.len == 1)
    return try derived2(vm, adv, base, args[0], f);
  if (args.len == 2)
    return try derived3(vm, adv, base, args[0], args[1], f);
  // N>2 args for non-each adverbs: pass through to base function directly
  return try f(vm, base, args);
}

fn derived2(vm: *VM, adv: Adverb, x: V, y: V, f: anytype) !V {
  const xt = x.tag();
  const base_is_radix = xt == .I or xt == .i or xt == .b;
  const base_is_char = xt == .c or xt == .C;
  switch (adv) {
    .@"'" => {
      if (xt==.i) return try window(vm, x, y);
      return try each1(vm, x, y, f);
    },
    .@"/" => {
      if (base_is_radix) return try decode(vm, x, y);
      if (base_is_char) return try join(vm, x, y);
      // converge
      return try fold(vm, x, null, y, f);
    },
    .@"\\" => {
      if (base_is_radix) return try encode(vm, x, y);
      if (base_is_char) return try split(vm, x, y);
      // converges
      return try scan(vm, x, null, y, f);
    },
    .@"':" => {
      if (xt == .i) return try window(vm, x, y);
      return try eachprior(vm, x, null, y, f);
    },
    else => @panic("unknown adverb")
  }
}

fn derived3(vm: *VM, adv: Adverb, x: V, y: V, z: V, f: anytype) !V {
  return switch (adv) {
    .@"'" => {
      // if (xt==.i) return try stencil(vm, y, x, z, f);
      return .{.err=.nyi};
    },
    .@"/" => {
      // seeded fold: x F/ y → fold y with seed x
      return try fold(vm, x, y, z, f);
    },
    .@"\\" => {
      // seeded scan: x F\ y → scan y with seed x
      return try scan(vm, x, y, z, f);
    },
    .@"':" => return try eachprior(vm, x, y, z, f),
    .@"/:" => try eachright(vm, x, y, z, f),
    .@"\\:" => try eachleft(vm, x, y, z, f),
  };
}

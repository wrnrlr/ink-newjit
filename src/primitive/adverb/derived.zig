const std = @import("std");
const Alloc = std.mem.Allocator;
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const V = value.V;
const Adverb = value.Adverb;
const util = @import("../../util.zig");

pub const converge = @import("converge.zig").converge;
pub const converges = @import("converges.zig").converges;
const whiledo = @import("whiledo.zig").whiledo;
const whilescan = @import("whiledo.zig").whilescan;
const decode = @import("decode.zig").decode;
const ndo = @import("ndo.zig").ndo;
const ndos = @import("ndos.zig").ndos;
const each = @import("each.zig").each;
const zip = @import("zip.zig").each2;
const eachleft = @import("eachleft.zig").eachleft;
const eachprior = @import("eachprior.zig").eachprior;
const eachright = @import("eachright.zig").eachright;
const encode = @import("encode.zig").encode;
const fold = @import("fold.zig").fold;
const join = @import("join.zig").join;
const scan = @import("scan.zig").scan;
const split = @import("split.zig").split;
const stencil  = @import("stencil.zig").stencil;
const window = @import("window.zig").window;

pub fn derived(vm: *VM, base: V, adv: Adverb, args: []const V, f: util.ApplyFn) V {
  // Stencil: f'[n;x] — integer n means window size, not each2 broadcast
  if (adv == .@"'" and args.len == 2 and args[0].tag() == .i
      and base.tag() == .func and base.func.getRealArity() == 1)
    return stencil(vm, args[0], base, args[1], f);
  // Multi-arg each: f'[x;y;...] → apply base to element-wise tuples
  if (adv == .@"'" and args.len >= 2)
    return zip(vm, base, args, f);
  if (args.len == 1)
    return derived2(vm, adv, base, args[0], f);
  if (args.len == 2)
    return derived3(vm, adv, base, args[0], args[1], f);
  // N>2 args for non-each adverbs: pass through to base function directly
  return f(vm, base, args);
}

fn derived2(vm: *VM, adv: Adverb, x: V, y: V, f: util.ApplyFn) V {
  const xt = x.tag();
  const base_is_radix = xt == .I or xt == .i or xt == .b;
  const base_is_char = xt == .c or xt == .C;
  switch (adv) {
    .@"'" => {
      if (xt==.i) return window(vm, x, y);
      return each(vm, x, y, f);
    },
    .@"/" => {
      if (base_is_radix) return decode(vm, x, y);
      if (base_is_char) return join(vm, x, y);
      if (x.arity() == 1) return converge(vm, x, y, f);
      return fold(vm, x, null, y, f);
    },
    .@"\\" => {
      if (base_is_radix) return encode(vm, x, y);
      if (base_is_char) return split(vm, x, y);
      if (x.arity() == 1) return converges(vm, x, y, f);
      return scan(vm, x, null, y, f);
    },
    .@"':" => {
      if (xt == .i) return window(vm, x, y);
      return eachprior(vm, x, null, y, f);
    },
    else => @panic("unknown adverb")
  }
}

fn derived3(vm: *VM, adv: Adverb, x: V, y: V, z: V, f: util.ApplyFn) V {
  return switch (adv) {
    .@"'" => return .{.err=.nyi},
    .@"/" => {
      if (y.tag() == .i and x.tag() == .func and x.func.getRealArity() == 1)
        return ndo(vm, x, y.i, z, f);
      if ((y.tag() == .func or y.tag() == .partial) and x.tag() == .func)
        return whiledo(vm, y, x, z, f);
      return fold(vm, x, y, z, f);
    },
    .@"\\" => {
      if (y.tag() == .i and x.tag() == .func and x.func.getRealArity() == 1)
        return ndos(vm, x, y.i, z, f);
      if ((y.tag() == .func or y.tag() == .partial) and x.tag() == .func)
        return whilescan(vm, y, x, z, f);
      return scan(vm, x, y, z, f);
    },
    .@"':" => eachprior(vm, x, y, z, f),
    .@"/:" => eachright(vm, x, y, z, f),
    .@"\\:" => eachleft(vm, x, y, z, f),
  };
}

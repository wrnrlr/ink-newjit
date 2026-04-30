const value = @import("../noun/value.zig");
const gpu_mod = @import("../gpu/gpu.zig");
const Op = @import("../runtime/tape.zig").Op;
const K = @import("../noun/class.zig").K;
const util = @import("../util.zig");
const verbs = @import("verb/verbs.zig");
const concat = @import("verb/concat.zig");
const pair = @import("verb/pair.zig");
const promote = @import("promote.zig").promote;
const VM = @import("../runtime/vm.zig").VM;

const V = value.V;
const N = value.N;

pub fn dispatch1(vm: *VM, op: Op, x: V) anyerror!V {
  const xt = x.tag();
  // Fast path: common scalar monads — avoid table lookup indirection.
  if (xt == .i) switch (op) {
    .@"-" => return .{ .i = -%x.i },
    .@"~" => return .{ .b = x.i == 0 },
    .@"#" => return .{ .i = 1 },
    else  => {},
  };
  if (xt == .f) switch (op) {
    .@"-" => return .{ .f = -x.f },
    .@"~" => return .{ .b = x.f == 0.0 },
    .@"#" => return .{ .i = 1 },
    else  => {},
  };
  const key = op.code() * K.COUNT + xt.code();
  if (verbs.monad_table[key]) |f| return f(vm, x);
  return switch (xt) {
    .m => try fallbackDict(vm, op, x.m.av(), x.m.bv(), .m),
    .M => try fallbackDict(vm, op, x.M.av(), x.M.bv(), .M),
    .L => fallbackList(vm, op, x),
    else => .{ .err = .@"type" }
  };
}

pub fn dispatch2(vm: *VM, op: Op, x: V, y: V) anyerror!V {
  const xt = x.tag();
  const yt = y.tag();

  // Fast paths for scalar arithmetic — the hot case in fold/scan inner loops.
  // These bypass table lookup + function-pointer indirection.
  if (xt == .i and yt == .i) switch (op) {
    .@"+" => return .{ .i = x.i +% y.i },
    .@"-" => return .{ .i = x.i -% y.i },
    .@"*" => return .{ .i = x.i *% y.i },
    .@"&" => return .{ .i = @min(x.i, y.i) },
    .@"|" => return .{ .i = @max(x.i, y.i) },
    .@"<" => return .{ .b = x.i < y.i },
    .@">" => return .{ .b = x.i > y.i },
    .@"=" => return .{ .b = x.i == y.i },
    else  => {},
  };
  if (xt == .f and yt == .f) switch (op) {
    .@"+" => return .{ .f = x.f + y.f },
    .@"-" => return .{ .f = x.f - y.f },
    .@"*" => return .{ .f = x.f * y.f },
    .@"%" => return .{ .f = x.f / y.f },
    .@"&" => return .{ .f = @min(x.f, y.f) },
    .@"|" => return .{ .f = @max(x.f, y.f) },
    .@"<" => return .{ .b = x.f < y.f },
    .@">" => return .{ .b = x.f > y.f },
    .@"=" => return .{ .b = x.f == y.f },
    else  => {},
  };

  // GPU shortcut: both operands already GPU-resident — stay on GPU.
  if (vm.gpu) |g| gpu_blk: {
    const dyad_op: gpu_mod.DyadOp = switch (op) {
      .@"+" => .add, .@"-" => .sub, .@"*" => .mul, .@"%" => .div,
      .@"&" => .min, .@"|" => .max,
      else => break :gpu_blk,
    };
    if (xt == .I and yt == .I and x.I.isGpu() and y.I.isGpu()) {
      if (x.I.ptr.len != y.I.ptr.len) return V{ .err = .length };
      const n: u32 = @intCast(x.I.ptr.len);
      const out_range = try g.allocRange(n * @sizeOf(i32));
      try g.dyadI32(dyad_op, out_range, x.I.gpuRange(), y.I.gpuRange(), n);
      return .{ .I = try N(i32).initGpu(g, out_range, n) };
    }
    if (xt == .F and yt == .F and x.F.isGpu() and y.F.isGpu()) {
      if (x.F.ptr.len != y.F.ptr.len) return V{ .err = .length };
      const n: u32 = @intCast(x.F.ptr.len);
      const out_range = try g.allocRange(n * @sizeOf(f32));
      try g.dyadF32(dyad_op, out_range, x.F.gpuRange(), y.F.gpuRange(), n);
      return .{ .F = try N(f32).initGpu(g, out_range, n) };
    }
  }
  const key = op.code() * K.COUNT * K.COUNT + xt.code() * K.COUNT + yt.code();
  if (verbs.dyad_table[key]) |f| return f(vm, x, y);
  if (op == .@",") return concat.apply(vm, x, y);
  if (op == .@"!") return pair.dict(vm, x, y);
  if (op == .@"~") return .{ .b = x.eq(y) };
  if (xt == .L or yt == .L or x.isDict() or y.isDict()) return listDyad(vm, op, x, y);
  return .{ .err = .@"type" };
}

fn fallbackDict(vm: *VM, op: Op, av: V, bv: V, comptime k:K) !V {
  const r = try dispatch1(vm, op, bv);
  if (r.tag() == .err) return r;
  errdefer r.deinit(vm.alloc);
  return V.wrap(k, try value.Dict.init(vm.alloc, av.ref(), r));
}

fn fallbackList(vm: *VM, op: Op, x: V) !V {
  // TODO cow?
  const n = x.len();
  const res = try N(V).init(vm.alloc, n);
  @memset(res.slice(), .blank);
  errdefer (V{ .L = res }).deinit(vm.alloc);

  for (res.slice(), 0..) |*r, i| {
    const val = x.at(i);
    defer val.deinit(vm.alloc);
    const rv = try dispatch1(vm, op, val);
    if (rv.tag() == .err) {
      (V{ .L = res }).deinit(vm.alloc);
      return rv;
    }
    r.* = rv;
  }
  return V{ .L = res };
}

fn listDyad(vm: *VM, op: Op, x: V, y: V) !V {
  if (x.isDict() or y.isDict()) {
    if (x.isDict() and y.isDict()) {
      const x_av = switch (x) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
      const y_av = switch (y) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
      if (!x_av.eq(y_av)) return V{ .err = .length };
      const x_bv = switch (x) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
      const y_bv = switch (y) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
      const vals = try dispatch2(vm, op, x_bv, y_bv);
      if (vals.tag() == .err) return vals;
      errdefer vals.deinit(vm.alloc);
      return switch (x) {
        .m => V{ .m = try value.Dict.init(vm.alloc, x_av.ref(), vals) },
        .M => V{ .M = try value.Dict.init(vm.alloc, x_av.ref(), vals) },
        else => unreachable,
      };
    }
    if (x.isDict()) {
      const x_av = switch (x) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
      const x_bv = switch (x) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
      const vals = try dispatch2(vm, op, x_bv, y);
      if (vals.tag() == .err) return vals;
      errdefer vals.deinit(vm.alloc);
      return switch (x) {
        .m => V{ .m = try value.Dict.init(vm.alloc, x_av.ref(), vals) },
        .M => V{ .M = try value.Dict.init(vm.alloc, x_av.ref(), vals) },
        else => unreachable,
      };
    }
    const y_av = switch (y) { .m => |d| d.av(), .M => |d| d.av(), else => unreachable };
    const y_bv = switch (y) { .m => |d| d.bv(), .M => |d| d.bv(), else => unreachable };
    const vals = try dispatch2(vm, op, x, y_bv);
    if (vals.tag() == .err) return vals;
    errdefer vals.deinit(vm.alloc);
    return switch (y) {
      .m => V{ .m = try value.Dict.init(vm.alloc, y_av.ref(), vals) },
      .M => V{ .M = try value.Dict.init(vm.alloc, y_av.ref(), vals) },
      else => unreachable,
    };
  }
  const xn = x.len();
  const yn = y.len();
  const n = if (xn == 1) yn else if (yn == 1) xn else if (xn == yn) xn else return V{ .err = .length };
  const res = try N(V).init(vm.alloc, n);
  @memset(res.slice(), .blank);
  errdefer {
    const tmp = V{ .L = res };
    tmp.deinit(vm.alloc);
  }

  for (res.slice(), 0..) |*r, i| {
    const xv = if (xn == 1) x.ref() else x.at(i);
    defer xv.deinit(vm.alloc);
    const yv = if (yn == 1) y.ref() else y.at(i);
    defer yv.deinit(vm.alloc);
    const rv = try dispatch2(vm, op, xv, yv);
    if (rv.tag() == .err) return rv;
    r.* = rv;
  }
  return try promote(vm.alloc, res);
}

// pub const Kind = enum(u4) {
//   verb,   // monads, dyads, special (amend, drill, try, splice)
//   adverb,
//   lambda,
//   projection,  // partially applied 
//   composition, // train
//   derived,
//   external
// };

// pub const F = packed struct(u32) {
//   kind:  Kind,
//   arity: u3, // monad, dyad, triad, tetrad, pentad, hexad, heptad, octad
//   extra: u32, // either enum of verb op, adverb or special, or index of lambda, projection, composition, derived verb in table
  
//   fn op1(op: Op) F { return .{ .kind=.verb, .arity=1, .extra=@intFromEnum(op)}; }
//   fn op2(op: Op) F { return .{ .kind=.verb, .arity=2, .extra=@intFromEnum(op)}; }
//   fn special3(op: Op) F { return .{ .kind=.verb, .arity=3, .extra=@intFromEnum(op)}; }
//   fn special4(op: Op) F { return .{ .kind=.verb, .arity=4, .extra=@intFromEnum(op)}; }
//   fn adverb2(adv: Op) F { return .{ .kind=.adverb, .arity=2, .extra=adv}; }
//   fn adverb3(adv: Op) F { return .{ .kind=.adverb, .arity=3, .extra=adv}; } // for digraph like stencil: i f': stencil
//   fn lambda(arity: u3, idx: u32) F { return .{ .kind=.lambda, .arity=arity, .extra=idx}; }
//   fn projection(arity: u3, idx: u32) F { return .{ .kind=.projection, .arity=arity, .extra=idx}; }
//   fn composition(arity: u3, idx: u32) F { return .{ .kind=.composition, .arity=arity, .extra=idx}; }
//   fn derived(arity: u3, idx: u32) F { return .{ .kind=.derived, .arity=arity, .extra=idx}; }
//   fn external(arity: u3, idx: u32) F { return .{ .kind=.external, .arity=arity, .extra=idx}; }
// };

// pub const Entry = union {
//   lambda: struct {
//     arity:  u8,
//     locals: u8,
//     chunk:  *Chunk,
//     range:  u32,
//   },
//   projection: struct {},
//   composition: struct {},
//   derived: struct {},
//   external: struct {},
// };

// // Function table
// pub const Table = struct {
//   alloc:   Alloc,
//   entries: std.MultiArrayList(Entry) = .empty,
  
//   fn init(alloc: Alloc) !Table {
//     return .{ .entries = std.MultiArrayList(Entry).initCapacity(alloc, 0) };
//   }
// };


// monadic operators
// pub const Op1 = enum(u8) {
//   // @"%", // unimplemented
//   @"!", // iota or odometer
//   @"&", // where
//   @"+", // flip
//   @"*", // first
//   @"|", // reverse
//   @"<", // ascend or io open
//   @">", // descend or io close
//   @"=", // unimat
//   @"~", // not
//   @",", // enlist
//   @"^", // null
//   @"#", // tally
//   @"_", // floor or lowercase
//   @"$", // string
//   @"?", // distinct or uniform
//   @"@", // type
//   @"-", // negate
//   @".", // get 
//   sqrt, sqr, exp, log, sin, cos, abs,
//   last,
//   @"0:", // read lines
//   @"1:", // read bytes
//   // @"2:", // ignore, uninplemented
//   @"9:", // graphics (ignore, work in progress)
//   @":",  // right
  
//   const COUNT = @typeInfo(Op1).@"enum".fields.len;

//   pub fn fromString(s: []const u8) ?Op1 {
//     inline for (std.meta.fields(Op1)) |f| {
//       if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
//     }
//     return null;
//   }

//   pub fn toString(self: Op1) []const u8 { return @tagName(self); }
// };

// // dyadic operators
// pub const Op2 = enum(u8) {
//   @"%", // unimplemented
//   @"!", // iota or odometer
//   @"&", // where
//   @"+", // flip
//   @"*", // first
//   @"|", // reverse
//   @"<", // ascend or io open
//   @">", // descend or io close
//   @"=", // unimat
//   @"~", // not
//   @",", // enlist
//   @"^", // null
//   @"#", // tally
//   @"_", // floor or lowercase
//   @"$", // string
//   @"?", // distinct or uniform
//   @"@", // type
//   @"-", // negate
//   @".", // get 
//   @"0:", // write lines
//   @"1:", // write bytes
//   // @"2:", // ignore, uninplemented
//   // @"9:", // graphics (ignore, work in progress)
  
//   in, has,
  
//   const COUNT = @typeInfo(Op2).@"enum".fields.len;
  
//   pub fn fromString(s: []const u8) ?Op2 {
//     inline for (std.meta.fields(Op2)) |f| {
//       if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
//     }
//     return null;
//   }

//   pub fn toString(self: Op2) []const u8 { return @tagName(self); }
// };

// // Adverb without digram
// const Ad2 = enum {
//   @"'",   // each1
//   @"/",   // fold
//   @"\\",  // 
//   @"':",  // window, eachprior
//   @"/:",  //
//   @"\\:", //
// };

// // Adverb with digram
// const Ad3 = enum {
//   @"'",   // each2
//   @"/",   // seeded-fold, n-do, while
//   @"\\",  // sseeded-scan, n-dos, whiles
//   @"':",  // stencil
//   @"/:",  // each-right
//   @"\\:", // each-left
// };


// test "Monads" {
//   try std.testing.expect(Op1.COUNT == 30);
// }

// test "Dyads" {
//   try std.testing.expect(Op2.COUNT == 23);
// }

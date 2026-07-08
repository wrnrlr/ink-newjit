// Fused reduce-of-zip: `red/ (x bin y)` computed in a single pass without
// materialising the elementwise temp. The optimizer rewrites
// Apply1(red, Apply2(bin, x, y)) -> ReduceZip(red, bin)[x, y].
//
// A fast path covers same-type numeric vectors (I·I, F·F) for the common
// reduce/bin pairs; everything else falls back to the original two-step
// semantics (materialise x bin y, then reduce), so behaviour is unchanged.

const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const dispatch = @import("../dispatch.zig");
const tape = @import("../../runtime/tape.zig");
const KOp = tape.KOp;
const KInsn = tape.KInsn;
const Kernel = tape.Kernel;
const N = @import("../../noun/array.zig").N;
const K = @import("../../noun/class.zig").K;
const calc = @import("../verb/calc.zig");

// ── Fused elementwise map (FusedMap opcode) ───────────────────────────────────
// Evaluate a postfix arithmetic program (built by the compiler from a maximal
// pointwise subtree) over the leaf operands `ops`, in one chunked pass. Fast
// @Vector path when every operand is a same-type numeric vector/scalar; otherwise
// the postfix program is replayed via normal dispatch (materialising each
// intermediate) so the result is byte-identical to the unfused verb chain.
const LANES = 8;
const KDEPTH = 16;               // max eval-stack depth (compiler refuses deeper trees)
const BLOCK = 256;               // cache-block: interpret once per KOp per block, each KOp a
                                 // tight SIMD loop over L1-resident scratch (X100 vectorization).

pub fn fusedMap(vm: *VM, k: *const Kernel, ops: []const V) V {
  var n: usize = 0;              // common vector length (0 = no vector seen)
  var vec = false;
  var allF = true;
  var allI = true;
  for (ops) |o| switch (o.tag()) {
    .F => { vec = true; allI = false; if (n == 0) n = o.F.ptr.len else if (n != o.F.ptr.len) return fallback(vm, k, ops); },
    .I => { vec = true; allF = false; if (n == 0) n = o.I.ptr.len else if (n != o.I.ptr.len) return fallback(vm, k, ops); },
    .f => allI = false,
    .i => allF = false,
    else => return fallback(vm, k, ops),
  };
  if (!vec) return fallback(vm, k, ops);          // all-scalar: rare, let dispatch handle
  if (allF) return if (k.result_bool) runChunk(f32, true, vm, k, ops, n) else runChunk(f32, false, vm, k, ops, n);
  if (allI and !k.float_only) return if (k.result_bool) runChunk(i32, true, vm, k, ops, n) else runChunk(i32, false, vm, k, ops, n);
  return fallback(vm, k, ops);                     // mixed i32/f32, or float-only op on i32
}

// An eval-stack entry is either a vector leaf (read directly from the operand —
// no copy) or a materialized scratch block (an intermediate result).
const Src = union(enum) { leaf: u8, scr: u8 };

inline fn srcSlice(comptime T: type, e: Src, ops: []const V, scratch: *[KDEPTH][BLOCK]T, base: usize, w: usize) []const T {
  return switch (e) {
    .leaf => |i| @field(ops[i], if (T == f32) "F" else "I").slice()[base .. base + w],
    .scr => |s| scratch[s][0..w],
  };
}

// One dyadic op on scalars or @Vector lanes. Float-only ops are comptime-guarded
// for i32 (never reached — the classifier falls those kernels back to dispatch).
inline fn binOp(comptime T: type, comptime op: KOp, x: anytype, y: @TypeOf(x)) @TypeOf(x) {
  const Tx = @TypeOf(x);
  return switch (op) {
    .Add => calc.AddOp.f(x, y), .Sub => calc.SubOp.f(x, y), .Mul => calc.MulOp.f(x, y),
    .Min => calc.MinOp.f(x, y), .Max => calc.MaxOp.f(x, y),
    .Div => if (comptime T == f32) calc.DivOp.f(x, y) else unreachable,
    // Comparisons yield 0/1 in T (so downstream Min/Max = AND/OR, arithmetic promotes).
    .Lt, .Gt, .Eq => blk: {
      const m = switch (op) { .Lt => x < y, .Gt => x > y, .Eq => x == y, else => unreachable };
      if (comptime @typeInfo(Tx) == .vector) break :blk @select(T, m, @as(Tx, @splat(1)), @as(Tx, @splat(0)));
      break :blk if (m) @as(T, 1) else @as(T, 0);
    },
    else => unreachable,
  };
}
inline fn monOp(comptime T: type, comptime op: KOp, x: anytype) @TypeOf(x) {
  return switch (op) {
    .Neg => calc.NegOp.f(x), .Sqr => calc.SqrOp.f(x),
    .Sqrt => if (comptime T == f32) @sqrt(x) else unreachable,
    .Exp => if (comptime T == f32) @exp(x) else unreachable,
    .Log => if (comptime T == f32) @log(x) else unreachable,
    .Sin => if (comptime T == f32) @sin(x) else unreachable,
    .Cos => if (comptime T == f32) @cos(x) else unreachable,
    else => unreachable,
  };
}

// dst[i] = a[i] <op> b[i], SIMD + scalar tail. `op` comptime → straight-line body.
inline fn binInto(comptime T: type, comptime op: KOp, dst: []T, a: []const T, b: []const T) void {
  var i: usize = 0;
  const w = dst.len;
  while (i + LANES <= w) : (i += LANES) {
    const av: @Vector(LANES, T) = a[i..][0..LANES].*;
    const bv: @Vector(LANES, T) = b[i..][0..LANES].*;
    dst[i..][0..LANES].* = binOp(T, op, av, bv);
  }
  while (i < w) : (i += 1) dst[i] = binOp(T, op, a[i], b[i]);
}
inline fn monInto(comptime T: type, comptime op: KOp, dst: []T, a: []const T) void {
  var i: usize = 0;
  const w = dst.len;
  while (i + LANES <= w) : (i += LANES) {
    const av: @Vector(LANES, T) = a[i..][0..LANES].*;
    dst[i..][0..LANES].* = monOp(T, op, av);
  }
  while (i < w) : (i += 1) dst[i] = monOp(T, op, a[i]);
}

fn runChunk(comptime T: type, comptime OutBool: bool, vm: *VM, k: *const Kernel, ops: []const V, n: usize) V {
  const OutT = if (OutBool) bool else T;
  const out = N(OutT).init(vm.alloc, n) catch return V{ .err = .memory };
  const dst = out.slice();
  const vk: K = if (T == f32) .F else .I;
  var scratch: [KDEPTH][BLOCK]T = undefined;   // intermediate results (L1-resident)
  var stack: [KDEPTH]Src = undefined;
  const last = k.code.len - 1;                  // root op index (kernel is non-empty, nbin>=2)
  var base: usize = 0;
  while (base < n) : (base += BLOCK) {
    const w = @min(BLOCK, n - base);
    var sp: usize = 0;
    for (k.code, 0..) |ins, ci| switch (ins.op) {
      .Col => {
        const o = ops[ins.arg];
        if (o.tag() == vk) {
          stack[sp] = .{ .leaf = ins.arg };              // vector: read direct, no copy
        } else {                                          // scalar: splat into scratch once
          const s = @field(o, if (T == f32) "f" else "i");
          for (scratch[sp][0..w]) |*d| d.* = s;
          stack[sp] = .{ .scr = @intCast(sp) };
        }
        sp += 1;
      },
      inline .Add, .Sub, .Mul, .Min, .Max, .Div, .Lt, .Gt, .Eq => |op| {
        sp -= 1;
        const a = srcSlice(T, stack[sp - 1], ops, &scratch, base, w);
        const b = srcSlice(T, stack[sp], ops, &scratch, base, w);
        // Non-bool root writes straight to output; else (and all interiors) to scratch.
        const target = if (comptime OutBool) scratch[sp - 1][0..w] else (if (ci == last) dst[base .. base + w] else scratch[sp - 1][0..w]);
        binInto(T, op, target, a, b);
        stack[sp - 1] = .{ .scr = @intCast(sp - 1) };
      },
      inline .Neg, .Sqr, .Sqrt, .Exp, .Log, .Sin, .Cos => |op| {
        const a = srcSlice(T, stack[sp - 1], ops, &scratch, base, w);
        const target = if (comptime OutBool) scratch[sp - 1][0..w] else (if (ci == last) dst[base .. base + w] else scratch[sp - 1][0..w]);
        monInto(T, op, target, a);
        stack[sp - 1] = .{ .scr = @intCast(sp - 1) };
      },
    };
    if (OutBool) {   // convert the 0/1 result block to a B column
      const res = srcSlice(T, stack[0], ops, &scratch, base, w);
      for (0..w) |i| dst[base + i] = res[i] != 0;
    }
  }
  return V.wrap(if (OutBool) .B else vk, out);
}

// Replay the postfix program with the normal dyadic dispatch — identical to the
// unfused chain. Used for any operand shape the fast path doesn't cover.
fn fallback(vm: *VM, k: *const Kernel, ops: []const V) V {
  var st: [KDEPTH]V = undefined;
  var sp: usize = 0;
  for (k.code) |ins| switch (ins.op) {
    .Col => { st[sp] = ops[ins.arg].ref(); sp += 1; },
    .Neg, .Sqr, .Sqrt, .Exp, .Log, .Sin, .Cos => {
      const o1: Op1 = switch (ins.op) {
        .Neg => .@"-", .Sqr => .sqr, .Sqrt => .sqrt, .Exp => .exp, .Log => .log, .Sin => .sin, .Cos => .cos, else => unreachable,
      };
      const r = dispatch.dispatch1(vm, o1, st[sp - 1]);
      st[sp - 1].deinit(vm.alloc);
      st[sp - 1] = r;
    },
    else => {
      const o2: Op2 = switch (ins.op) {
        .Add => .@"+", .Sub => .@"-", .Mul => .@"*", .Min => .@"&", .Max => .@"|", .Div => .@"%",
        .Lt => .@"<", .Gt => .@">", .Eq => .@"=", else => unreachable,
      };
      sp -= 1;
      const r = dispatch.dispatch2(vm, o2, st[sp - 1], st[sp]);
      st[sp - 1].deinit(vm.alloc);
      st[sp].deinit(vm.alloc);
      st[sp - 1] = r;
    },
  };
  return st[0];
}

pub fn reduceZip(vm: *VM, red: Op1, bin: Op2, x: V, y: V) V {
  const xt = x.tag();
  if (xt == y.tag() and (xt == .I or xt == .F) and x.len() == y.len() and x.len() > 0) {
    if (fast(red, bin, x, y)) |r| return r;
  }
  // Fallback: identical to the unfused `red/ (x bin y)`.
  const tmp = dispatch.dispatch2(vm, bin, x, y);
  if (tmp.tag() == .err) return tmp;
  defer tmp.deinit(vm.alloc);
  return dispatch.dispatch1(vm, red, tmp);
}

fn fast(red: Op1, bin: Op2, x: V, y: V) ?V {
  switch (x.tag()) {
    inline .I, .F => |t| {
      const T = comptime if (t == .I) i32 else f32;
      return fastT(T, red, bin, @field(x, @tagName(t)).slice(), @field(y, @tagName(t)).slice());
    },
    else => return null,
  }
}

fn fastT(comptime T: type, red: Op1, bin: Op2, xs: []const T, ys: []const T) ?V {
  inline for (.{ Op1.@"+/", Op1.@"*/", Op1.@"&/", Op1.@"|/" }) |R| {
    if (red == R) {
      inline for (.{ Op2.@"+", Op2.@"-", Op2.@"*", Op2.@"&", Op2.@"|", Op2.@"<", Op2.@">", Op2.@"=" }) |B| {
        if (bin == B) return kernel(T, R, B, xs, ys);
      }
      return null;
    }
  }
  return null;
}

inline fn isCmp(comptime B: Op2) bool { return B == .@"<" or B == .@">" or B == .@"="; }

fn kernel(comptime T: type, comptime R: Op1, comptime B: Op2, xs: []const T, ys: []const T) ?V {
  const is_int = comptime T == i32;
  if (comptime isCmp(B)) {
    // Comparison intermediate is boolean; reduce it.
    return switch (R) {
      .@"+/" => blk: { // count of true
        var acc: i32 = 0;
        for (xs, ys) |a, b| { if (cmpf(B, a, b)) acc += 1; }
        break :blk V{ .i = acc };
      },
      .@"&/" => blk: { // all
        for (xs, ys) |a, b| { if (!cmpf(B, a, b)) break :blk V{ .b = false }; }
        break :blk V{ .b = true };
      },
      .@"|/" => blk: { // any
        for (xs, ys) |a, b| { if (cmpf(B, a, b)) break :blk V{ .b = true }; }
        break :blk V{ .b = false };
      },
      else => null, // */ over bool not defined by the reducers — fall back
    };
  } else {
    var acc: T = arithf(B, xs[0], ys[0], is_int);
    for (xs[1..], ys[1..]) |a, b| acc = combinef(R, acc, arithf(B, a, b, is_int), is_int);
    return if (is_int) V{ .i = acc } else V{ .f = acc };
  }
}

inline fn cmpf(comptime B: Op2, a: anytype, b: @TypeOf(a)) bool {
  return switch (B) { .@"<" => a < b, .@">" => a > b, .@"=" => a == b, else => unreachable };
}

inline fn arithf(comptime B: Op2, a: anytype, b: @TypeOf(a), comptime is_int: bool) @TypeOf(a) {
  return switch (B) {
    .@"+" => if (is_int) a +% b else a + b,
    .@"-" => if (is_int) a -% b else a - b,
    .@"*" => if (is_int) a *% b else a * b,
    .@"&" => @min(a, b),
    .@"|" => @max(a, b),
    else => unreachable,
  };
}

inline fn combinef(comptime R: Op1, acc: anytype, e: @TypeOf(acc), comptime is_int: bool) @TypeOf(acc) {
  return switch (R) {
    .@"+/" => if (is_int) acc +% e else acc + e,
    .@"*/" => if (is_int) acc *% e else acc * e,
    .@"&/" => @min(acc, e),
    .@"|/" => @max(acc, e),
    else => unreachable,
  };
}

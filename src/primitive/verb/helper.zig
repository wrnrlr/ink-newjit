const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const dispatch = @import("../dispatch.zig");
const promote = @import("../promote.zig").promote;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;
pub const Attr = std.builtin.Type.StructField.Attributes;

pub const all_types = [_]K{ .blank, .err, .b, .i, .f, .s, .c, .m, .B, .I, .F, .S, .C, .M, .L, .x };
pub const numeric_types = [_]K{ .b, .i, .f, .B, .I, .F };
pub const arithmetic_types = [_]K{ .b, .i, .f, .B, .I, .F }; //, .L, .m, .M };
pub const integer_types = [_]K{ .i, .I };
pub const cut_types = [_]K{ .b, .i, .f, .B, .I, .F };

/// Wrap a hand-written handler struct (one that already contains _* fields
/// with default MonadFn/DyadFn values) by injecting the `op` field so the
/// dispatch-table builder can key it correctly. EnumT is Op1 (monad) or Op2
/// (dyad) so the dispatch-table builder gets the typed value directly.
pub fn _X(comptime EnumT: type, comptime op: EnumT, comptime Impl: type) type {
  const op_default: EnumT = op;
  var names: []const []const u8 = &.{ "op" };
  var types: []const type       = &.{ EnumT };
  var attrs: []const Attr       = &.{ .{ .default_value_ptr = @ptrCast(&op_default) } };
  for (std.meta.fields(Impl)) |f| {
    const attr: Attr = .{ .default_value_ptr = f.default_value_ptr.? };
    names = names ++ .{f.name};
    types = types ++ .{f.type};
    attrs = attrs ++ .{attr};
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(types[0..n].*), &(attrs[0..n].*));
}

pub fn _Y(comptime op: Op1, comptime ks: []const K, comptime f: VM.Monad) type {
  var names: []const []const u8 = &.{ "op" };
  var types: []const type = &.{ Op1 };
  var attrs: []const Attr = &.{ .{ .default_value_ptr = @ptrCast(&op) } };
  for (ks) |xk| {
    names = names ++ .{"_" ++ @tagName(xk)};
    types = types ++ .{VM.Monad};
    const attr: Attr = .{ .default_value_ptr = @ptrCast(&f) };
    attrs = attrs ++ .{attr};
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(types[0..n].*), &(attrs[0..n].*));
}

pub fn makeMonad(
  comptime operator: @import("../../noun/operator.zig").Op1,
  comptime CastType: fn (type) type,
  comptime ResultType: fn (type) type,
  comptime Impl: type,
  comptime ks: []const K,
) type {
  const op_default: Op1 = operator;
  var names: []const []const u8 = &.{ "op" };
  var types: []const type = &.{ Op1 };
  var attrs: []const Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (ks) |xk| {
    const maybe: ?VM.Monad = monadKernel(xk, CastType, ResultType, Impl);
    if (maybe) |handler| {
      names = names ++ .{"_" ++ @tagName(xk)};
      types = types ++ .{VM.Monad};
      const attr: Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(types[0..n].*), &(attrs[0..n].*));
}

pub fn makeDyad(
  comptime operator: Op2,
  comptime CastType: fn (type, type) type,
  comptime ResultType: fn (type, type) type,
  comptime Impl: type,
  comptime types: []const K,
) type {
  @setEvalBranchQuota(2000000);
  const op_default: Op2 = operator;
  var names: []const []const u8 = &.{ "op" };
  var field_types: []const type = &.{ Op2 };
  var attrs: []const Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (types) |xk| {
    for (types) |yk| {
      const maybe: ?VM.Dyad = dyadKernel(xk, yk, CastType, ResultType, Impl);
      if (maybe) |handler| {
        names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
        field_types = field_types ++ .{VM.Dyad};
        const attr: Attr = .{ .default_value_ptr = @ptrCast(&handler) };
        attrs = attrs ++ .{attr};
      }
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}


// ── Result-type strategies ────────────────────────────────────────────────────

pub fn Upcast2(comptime T1: type, comptime T2: type) type {
  if (T1 == f32 or T2 == f32) return f32;
  return i32;
}
pub fn Float2(comptime _: type, comptime _: type) type { return f32; }
pub fn Int2(comptime _: type, comptime _: type) type { return i32; }
pub fn Bool2(comptime _: type, comptime _: type) type { return bool; }

pub fn Upcast1(comptime T: type) type { return if (T == f32) f32 else i32; }
pub fn Float1(comptime _: type) type { return f32; }
pub fn Int1(comptime _: type) type { return i32; }
pub fn Bool1(comptime _: type) type { return bool; }
pub fn Char1(comptime _: type) type { return u8; }

// ── Result-kind helpers ───────────────────────────────────────────────────────

pub fn resultKind1(comptime xk: K, comptime RT: fn (type) type) K {
  const R = RT(xk.backing());
  const scalar: K = if (R == f32) .f else if (R == bool) .b else if (R == u8) .c else if (R == u32) .n else .i;
  return if (xk.isVec()) scalar.container() else scalar;
}

pub fn resultKind2(comptime xk: K, comptime yk: K, comptime RT: fn (type, type) type) K {
  const R = RT(xk.backing(), yk.backing());
  const scalar: K = if (R == f32) .f else if (R == bool) .b else if (R == u32) .n else .i;
  return if (xk.isVec() or yk.isVec()) scalar.container() else scalar;
}

// ── Numeric kernel generators ─────────────────────────────────────────────────

fn monadKernel(
  comptime xk: K,
  comptime CastType: fn (type) type,
  comptime ResultType: fn (type) type,
  comptime Impl: type,
) VM.Monad {
  const XT = xk.backing();
  const C  = CastType(XT);
  const R  = ResultType(XT);
  const rk = resultKind1(xk, ResultType);
  return &struct {
    fn kernel(vm: *VM, x: V) V {
      if (comptime xk.isAtom()) return kernelAtom(xk, C, R, rk, Impl, x);
      if (comptime xk.isVec()) return kernelVec(xk, C, R, rk, Impl, vm, x);
      return V{ .err = .@"type" };
    }
  }.kernel;
}

fn Caster(comptime C: type) type {
  return struct {
    inline fn cast(v: anytype) C {
      const T = @TypeOf(v);
      if (T == C) return v;
      if (T == bool) return if (C == f32) (if (v) @as(f32, 1.0) else 0.0) else @intFromBool(v);
      if (T == i32 and C == f32) return @floatFromInt(v);
      if (T == f32 and C == i32) return @intFromFloat(v);
      if (T == u32 and C == f32) return @floatFromInt(v);
      unreachable;
    }
  };
}

// ── SIMD elementwise kernels ──────────────────────────────────────────────────
// Explicit @Vector loops for the pointwise ops. LLVM does not auto-vectorize the
// scalar loops in ReleaseFast (measured), so these are the only way we get
// NEON/SSE. Gated on: the op is @Vector-safe (marked `pub const simd`), and the
// cast type C, result type R, and operand element types are all i32/f32/bool
// (char/symbol/u32 columns fall back to scalar). C→R may differ — arithmetic has
// R==C, comparisons have R==bool (F.f returns a bool-vector on vector operands),
// bool `&`/`|` have C==R==bool. Results are bit-identical to the scalar path
// because the same op body runs on the lanes; the scalar tail handles n%8.
const LANES = 8;

inline fn numOk(comptime T: type) bool { return T == i32 or T == f32; }
inline fn simdT(comptime T: type) bool { return T == i32 or T == f32 or T == bool; }

inline fn vcast(comptime From: type, comptime To: type, v: @Vector(LANES, From)) @Vector(LANES, To) {
  if (From == To) return v;
  if (From == i32 and To == f32) return @floatFromInt(v);
  if (From == f32 and To == i32) return @intFromFloat(v);
  if (From == bool and To == i32) return @intFromBool(v);
  if (From == bool and To == f32) return @floatFromInt(@as(@Vector(LANES, i32), @intFromBool(v)));
  @compileError("vcast: unsupported vector cast");
}

// dst may alias xs (in-place); safe since dst[i] depends only on src[i].
inline fn vmap1(comptime XT: type, comptime C: type, comptime R: type, comptime F: type, dst: []R, xs: []const XT) void {
  const cast = Caster(C).cast;
  var i: usize = 0;
  const n = dst.len;
  while (i + LANES <= n) : (i += LANES) {
    const xv: @Vector(LANES, XT) = xs[i..][0..LANES].*;
    dst[i..][0..LANES].* = F.f(vcast(XT, C, xv));
  }
  while (i < n) : (i += 1) dst[i] = F.f(cast(xs[i]));
}

inline fn vmap2(comptime XT: type, comptime YT: type, comptime C: type, comptime R: type, comptime F: type, dst: []R, xs: []const XT, ys: []const YT) void {
  const cast = Caster(C).cast;
  var i: usize = 0;
  const n = dst.len;
  while (i + LANES <= n) : (i += LANES) {
    const xv: @Vector(LANES, XT) = xs[i..][0..LANES].*;
    const yv: @Vector(LANES, YT) = ys[i..][0..LANES].*;
    dst[i..][0..LANES].* = F.f(vcast(XT, C, xv), vcast(YT, C, yv));
  }
  while (i < n) : (i += 1) dst[i] = F.f(cast(xs[i]), cast(ys[i]));
}

// scalar-left ⊕ vector-right; `xc` is the left operand already cast to C.
inline fn vmapSV(comptime YT: type, comptime C: type, comptime R: type, comptime F: type, dst: []R, xc: C, ys: []const YT) void {
  const cast = Caster(C).cast;
  const sp: @Vector(LANES, C) = @splat(xc);
  var i: usize = 0;
  const n = dst.len;
  while (i + LANES <= n) : (i += LANES) {
    const yv: @Vector(LANES, YT) = ys[i..][0..LANES].*;
    dst[i..][0..LANES].* = F.f(sp, vcast(YT, C, yv));
  }
  while (i < n) : (i += 1) dst[i] = F.f(xc, cast(ys[i]));
}

// vector-left ⊕ scalar-right; `yc` is the right operand already cast to C.
inline fn vmapVS(comptime XT: type, comptime C: type, comptime R: type, comptime F: type, dst: []R, xs: []const XT, yc: C) void {
  const cast = Caster(C).cast;
  const sp: @Vector(LANES, C) = @splat(yc);
  var i: usize = 0;
  const n = dst.len;
  while (i + LANES <= n) : (i += LANES) {
    const xv: @Vector(LANES, XT) = xs[i..][0..LANES].*;
    dst[i..][0..LANES].* = F.f(vcast(XT, C, xv), sp);
  }
  while (i < n) : (i += 1) dst[i] = F.f(cast(xs[i]), yc);
}

fn kernelAtom(
  comptime xk: K,
  comptime C: type,
  comptime R: type,
  comptime rk: K,
  comptime F: type,
  x: V,
) V {
  const cast = Caster(C).cast;
  const r: R = F.f(cast(@field(x, @tagName(xk))));
  return V.wrap(rk, r);
}

fn kernelVec(
  comptime xk: K,
  comptime C: type,
  comptime R: type,
  comptime rk: K,
  comptime Impl: type,
  vm: *VM, x: V,
) V {
  const XT = xk.backing();
  const vx = @field(x, @tagName(xk));
  const simd = comptime @hasDecl(Impl, "simd") and simdT(C) and simdT(R) and simdT(XT);
  if (comptime R == XT and rk == xk) {
    if (vx.ptr.rc == 1) {
      if (comptime simd) vmap1(XT, C, R, Impl, vx.slice(), vx.slice())
      else for (vx.slice()) |*xv| xv.* = Impl.f(Caster(C).cast(xv.*));
      return x.ref();
    }
  }
  const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
  if (comptime simd) vmap1(XT, C, R, Impl, out.slice(), vx.slice())
  else for (vx.slice(), out.slice()) |xv, *r| r.* = Impl.f(Caster(C).cast(xv));
  return V.wrap(rk, out);
}

fn dyadKernel(
  comptime xk: K, comptime yk: K,
  comptime CastType: fn (type, type) type,
  comptime ResultType: fn (type, type) type,
  comptime Impl: type,
) VM.Dyad {
  const XT = xk.backing();
  const YT = yk.backing();
  const C  = CastType(XT, YT);
  const R  = ResultType(XT, YT);
  const rk = resultKind2(xk, yk, ResultType);
  const cast = Caster(C).cast;
  // SIMD applies when the op is @Vector-safe and the cast type, result type, and
  // the participating vector operands are all i32/f32/bool-backed. Atom operands
  // are cast to C and splatted; the scalar atom⊕atom case is unaffected.
  const simd = comptime @hasDecl(Impl, "simd") and simdT(C) and simdT(R);
  return &struct {
    fn kernel(vm: *VM, x: V, y: V) V {
      if (comptime xk.isAtom() and yk.isAtom()) {
        const r: R = Impl.f(cast(V.unwrap(x, xk)), cast(V.unwrap(y, yk)));
        return V.wrap(rk, r);
      }
      if (comptime xk.isAtom() and yk.isVec()) {
        const useSimd = comptime simd and simdT(YT);
        const xv = cast(V.unwrap(x, xk));
        const vy = V.unwrap(y, yk);
        if (comptime R == YT and rk == yk) {
          if (vy.ptr.rc == 1) {
            if (comptime useSimd) vmapSV(YT, C, R, Impl, vy.slice(), xv, vy.slice())
            else for (vy.slice()) |*yv| yv.* = Impl.f(xv, cast(yv.*));
            return y.ref();
          }
        }
        const out = N(R).init(vm.alloc, vy.ptr.len) catch return V{ .err = .memory };
        if (comptime useSimd) vmapSV(YT, C, R, Impl, out.slice(), xv, vy.slice())
        else for (vy.slice(), out.slice()) |yv, *r| r.* = Impl.f(xv, cast(yv));
        return V.wrap(rk, out);
      }
      if (comptime xk.isVec() and yk.isAtom()) {
        const useSimd = comptime simd and simdT(XT);
        const vx = V.unwrap(x, xk);
        const yv = cast(V.unwrap(y, yk));
        if (comptime R == XT and rk == xk) {
          if (vx.ptr.rc == 1) {
            if (comptime useSimd) vmapVS(XT, C, R, Impl, vx.slice(), vx.slice(), yv)
            else for (vx.slice()) |*xv| xv.* = Impl.f(cast(xv.*), yv);
            return x.ref();
          }
        }
        const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
        if (comptime useSimd) vmapVS(XT, C, R, Impl, out.slice(), vx.slice(), yv)
        else for (vx.slice(), out.slice()) |xv, *r| r.* = Impl.f(cast(xv), yv);
        return V.wrap(rk, out);
      }
      if (comptime xk.isVec() and yk.isVec()) {
        const useSimd = comptime simd and simdT(XT) and simdT(YT);
        const vx = @field(x, @tagName(xk));
        const vy = @field(y, @tagName(yk));
        if (vx.ptr.len != vy.ptr.len) return V{ .err = .length };
        if (comptime R == XT and rk == xk) {
          if (vx.ptr.rc == 1) {
            if (comptime useSimd) vmap2(XT, YT, C, R, Impl, vx.slice(), vx.slice(), vy.slice())
            else for (vx.slice(), vy.slice()) |*xv, yv| xv.* = Impl.f(cast(xv.*), cast(yv));
            return x.ref();
          }
        }
        if (comptime R == YT and rk == yk) {
          if (vy.ptr.rc == 1) {
            if (comptime useSimd) vmap2(XT, YT, C, R, Impl, vy.slice(), vx.slice(), vy.slice())
            else for (vx.slice(), vy.slice()) |xv, *yv| yv.* = Impl.f(cast(xv), cast(yv.*));
            return y.ref();
          }
        }
        const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
        if (comptime useSimd) vmap2(XT, YT, C, R, Impl, out.slice(), vx.slice(), vy.slice())
        else for (vx.slice(), vy.slice(), out.slice()) |xv, yv, *r| r.* = Impl.f(cast(xv), cast(yv));
        return V.wrap(rk, out);
      }
      return V{ .err = .@"type" };
    }
  }.kernel;
}

// ── Container dispatch (stage 2) ──────────────────────────────────────────────
// One runtime structural resolver shared by every op that broadcasts over
// containers. Cases (checked in order, each returns on match):
//   dict × dict  → key equality check, recurse on values, preserve x's dict type
//   dict × other → recurse on dict values vs y (includes dict × list)
//   other × dict → recurse on x vs dict values (includes list × dict)
//   list × other or other × list → element-wise with length broadcasting
//   anything else → type error
pub fn containerDyad(vm: *VM, op2: Op2, x: V, y: V) V {
  if (x.isDict() and y.isDict()) {
    const dx = dictOf(x);
    const dy = dictOf(y);
    if (!dx.av().eq(dy.av())) return V{ .err = .length };
    const vals = dispatch.dispatch2(vm, op2, dx.bv(), dy.bv());
    return rewrapDict(vm, x.tag(), dx.av(), vals);
  }
  if (x.isDict()) {
    const d = dictOf(x);
    const vals = dispatch.dispatch2(vm, op2, d.bv(), y);
    return rewrapDict(vm, x.tag(), d.av(), vals);
  }
  if (y.isDict()) {
    const d = dictOf(y);
    const vals = dispatch.dispatch2(vm, op2, x, d.bv());
    return rewrapDict(vm, y.tag(), d.av(), vals);
  }
  if (x.tag() == .L or y.tag() == .L) {
    const xn = x.len();
    const yn = y.len();
    const n = if (xn == 1) yn else if (yn == 1) xn else if (xn == yn) xn else return V{ .err = .length };
    const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
    @memset(res.slice(), .blank);
    for (res.slice(), 0..) |*r, i| {
      // Broadcast a count-1 operand by extracting its single element (.at(0)),
      // not by ref'ing the whole value: a length-1 *list* ref'd whole would
      // re-enter this same resolver with identical args and loop forever. .at(0)
      // on an atom returns the atom itself, so this is correct for both.
      const xv = x.at(if (xn == 1) 0 else i);
      defer xv.deinit(vm.alloc);
      const yv = y.at(if (yn == 1) 0 else i);
      defer yv.deinit(vm.alloc);
      const rv = dispatch.dispatch2(vm, op2, xv, yv);
      if (rv.tag() == .err) {
        (V{ .L = res }).deinit(vm.alloc);
        return rv;
      }
      r.* = rv;
    }
    return promote(vm.alloc, res);
  }
  return V{ .err = .@"type" };
}

fn dictOf(v: V) Dict {
  return switch (v) { .m, .M => |d| d, else => unreachable };
}

/// Rebuild a dict/table from recursed values, preserving the original tag.
/// Takes ownership of vals; propagates an error value unchanged.
fn rewrapDict(vm: *VM, t: K, keys: V, vals: V) V {
  if (vals.tag() == .err) return vals;
  const d = Dict.init(vm.alloc, keys.ref(), vals) catch {
    vals.deinit(vm.alloc);
    return V{ .err = .memory };
  };
  return if (t == .m) V{ .m = d } else V{ .M = d };
}

/// The per-op miss handler for broadcasting ops: a thin wrapper deferring to
/// containerDyad. Used as the stage-1 table's default slot and as the stage-2
/// row fallback for the non-quick broadcasting ops (= | & < > mod div).
pub fn containerFallback(comptime op2: Op2) VM.Dyad {
  return &struct {
    fn kernel(vm: *VM, x: V, y: V) V { return containerDyad(vm, op2, x, y); }
  }.kernel;
}

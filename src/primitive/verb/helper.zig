const std = @import("std");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const Op = @import("../../runtime/tape.zig").Op;
const Op2 = @import("../../noun/operator.zig").Op2;
const dispatch = @import("../dispatch.zig");
const promote = @import("../promote.zig").promote;
const V = @import("../../noun/value.zig").V;
const K = @import("../../noun/class.zig").K;
const N = @import("../../noun/array.zig").N;
const Dict = @import("../../noun/dict.zig").Dict;

pub const Attr = std.builtin.Type.StructField.Attributes;

pub const numeric_types    = [_]K{ .b, .i, .f, .B, .I, .F };
pub const arithmetic_types = [_]K{ .b, .i, .f, .B, .I, .F }; //, .L, .m, .M };
pub const integer_types    = [_]K{ .i, .I };
pub const cut_types = [_]K{ .b, .i, .f, .B, .I, .F };

/// Wrap a hand-written handler struct (one that already contains _* fields
/// with default MonadFn/DyadFn values) by injecting the `op` field so the
/// dispatch-table builder can key it correctly.
pub fn _X(comptime op: Op, comptime Impl: type) type {
  const op_default: Op = op;
  var names: []const []const u8 = &.{ "op" };
  var types: []const type       = &.{ Op };
  var attrs: []const Attr       = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (std.meta.fields(Impl)) |f| {
    const attr: Attr = .{ .default_value_ptr = f.default_value_ptr.? };
    names = names ++ .{f.name};
    types = types ++ .{f.type};
    attrs = attrs ++ .{attr};
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(types[0..n].*), &(attrs[0..n].*));
}

pub fn makeMonad(
  comptime operator: Op,
  comptime CastType: fn (type) type,
  comptime ResultType: fn (type) type,
  comptime Impl: type,
  comptime ks: []const K,
) type {
  const op_default: Op = operator;
  var names: []const []const u8 = &.{ "op" };
  var types: []const type = &.{ Op };
  var attrs: []const Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (ks) |xk| {
    const maybe: ?util.MonadFn = monadKernel(xk, CastType, ResultType, Impl);
    if (maybe) |handler| {
      names = names ++ .{"_" ++ @tagName(xk)};
      types = types ++ .{util.MonadFn};
      const attr: Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(types[0..n].*), &(attrs[0..n].*));
}

pub fn makeDyad(
  comptime operator: Op,
  comptime CastType: fn (type, type) type,
  comptime ResultType: fn (type, type) type,
  comptime Impl: type,
  comptime types: []const K,
) type {
  @setEvalBranchQuota(2000000);
  const op_default: Op = operator;
  var names: []const []const u8 = &.{ "op" };
  var field_types: []const type = &.{ Op };
  var attrs: []const Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  for (types) |xk| {
    for (types) |yk| {
      const maybe: ?util.DyadFn = dyadKernel(xk, yk, CastType, ResultType, Impl);
      if (maybe) |handler| {
        names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
        field_types = field_types ++ .{util.DyadFn};
        const attr: Attr = .{ .default_value_ptr = @ptrCast(&handler) };
        attrs = attrs ++ .{attr};
      }
    }
  }
  const all_k = comptime blk: {
    const fields = @typeInfo(K).@"enum".fields;
    var ts: [fields.len]K = undefined;
    for (fields, 0..) |f, i| ts[i] = @enumFromInt(f.value);
    break :blk ts;
  };
  for (all_k) |xk| {
    for (all_k) |yk| {
      if (dyadContainerKernel(xk, yk, operator)) |handler| {
        names = names ++ .{"_" ++ @tagName(xk) ++ "_" ++ @tagName(yk)};
        field_types = field_types ++ .{util.DyadFn};
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

// ── Result-kind helpers ───────────────────────────────────────────────────────

pub fn resultKind1(comptime xk: K, comptime RT: fn (type) type) K {
  const R = RT(xk.backing());
  const scalar: K = if (R == f32) .f else if (R == bool) .b else .i;
  return if (xk.isVec()) scalar.container() else scalar;
}

pub fn resultKind2(comptime xk: K, comptime yk: K, comptime RT: fn (type, type) type) K {
  const R = RT(xk.backing(), yk.backing());
  const scalar: K = if (R == f32) .f else if (R == bool) .b else .i;
  return if (xk.isVec() or yk.isVec()) scalar.container() else scalar;
}

// ── Numeric kernel generators ─────────────────────────────────────────────────

fn monadKernel(
  comptime xk: K,
  comptime CastType: fn (type) type,
  comptime ResultType: fn (type) type,
  comptime Impl: type,
) util.MonadFn {
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
      unreachable;
    }
  };
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
  const cast = Caster(C).cast;
  const vx = @field(x, @tagName(xk));
  if (comptime R == XT and rk == xk) {
    if (vx.ptr.rc == 1) {
      for (vx.slice()) |*xv| xv.* = Impl.f(cast(xv.*));
      return x.ref();
    }
  }
  const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
  for (vx.slice(), out.slice()) |xv, *r| r.* = Impl.f(cast(xv));
  return V.wrap(rk, out);
}

fn dyadKernel(
  comptime xk: K, comptime yk: K,
  comptime CastType: fn (type, type) type,
  comptime ResultType: fn (type, type) type,
  comptime Impl: type,
) util.DyadFn {
  const XT = xk.backing();
  const YT = yk.backing();
  const C  = CastType(XT, YT);
  const R  = ResultType(XT, YT);
  const rk = resultKind2(xk, yk, ResultType);
  return &struct {
    inline fn cast(v: anytype) C {
      const T = @TypeOf(v);
      if (T == C) return v;
      if (T == bool) return if (C == f32) (if (v) @as(f32, 1.0) else 0.0) else @intFromBool(v);
      if (T == i32 and C == f32) return @floatFromInt(v);
      if (T == f32 and C == i32) return @intFromFloat(v);
      unreachable;
    }
    fn kernel(vm: *VM, x: V, y: V) V {
      if (comptime xk.isAtom() and yk.isAtom()) {
        const r: R = Impl.f(cast(V.unwrap(x, xk)), cast(V.unwrap(y, yk)));
        return V.wrap(rk, r);
      }
      if (comptime xk.isAtom() and yk.isVec()) {
        const xv = cast(V.unwrap(x, xk));
        const vy = V.unwrap(y, yk);
        if (comptime R == YT and rk == yk) {
          if (vy.ptr.rc == 1) {
            for (vy.slice()) |*yv| yv.* = Impl.f(xv, cast(yv.*));
            return y.ref();
          }
        }
        const out = N(R).init(vm.alloc, vy.ptr.len) catch return V{ .err = .memory };
        for (vy.slice(), out.slice()) |yv, *r| r.* = Impl.f(xv, cast(yv));
        return V.wrap(rk, out);
      }
      if (comptime xk.isVec() and yk.isAtom()) {
        const vx = V.unwrap(x, xk);
        const yv = cast(V.unwrap(y, yk));
        if (comptime R == XT and rk == xk) {
          if (vx.ptr.rc == 1) {
            for (vx.slice()) |*xv| xv.* = Impl.f(cast(xv.*), yv);
            return x.ref();
          }
        }
        const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
        for (vx.slice(), out.slice()) |xv, *r| r.* = Impl.f(cast(xv), yv);
        return V.wrap(rk, out);
      }
      if (comptime xk.isVec() and yk.isVec()) {
        const vx = @field(x, @tagName(xk));
        const vy = @field(y, @tagName(yk));
        if (vx.ptr.len != vy.ptr.len) return V{ .err = .length };
        if (comptime R == XT and rk == xk) {
          if (vx.ptr.rc == 1) {
            for (vx.slice(), vy.slice()) |*xv, yv| xv.* = Impl.f(cast(xv.*), cast(yv));
            return x.ref();
          }
        }
        if (comptime R == YT and rk == yk) {
          if (vy.ptr.rc == 1) {
            for (vx.slice(), vy.slice()) |xv, *yv| yv.* = Impl.f(cast(xv), cast(yv.*));
            return y.ref();
          }
        }
        const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
        for (vx.slice(), vy.slice(), out.slice()) |xv, yv, *r| r.* = Impl.f(cast(xv), cast(yv));
        return V.wrap(rk, out);
      }
      return V{ .err = .@"type" };
    }
  }.kernel;
}

// ── Container kernel generators ───────────────────────────────────────────────

// Generates a broadcasting kernel for (xk, yk) when at least one is L/m/M.
// Returns null for pure scalar/vector pairs — those are handled by dyadKernel.
//
// Cases (checked in order, each returns on match):
//   dict × dict  → key equality check, recurse on values, preserve x's dict type
//   dict × other → recurse on dict values vs y (includes dict × list)
//   other × dict → recurse on x vs dict values (includes list × dict)
//   list × other or other × list → element-wise with length broadcasting
pub fn dyadContainerKernel(
  comptime xk: K,
  comptime yk: K,
  comptime operator: Op,
) ?util.DyadFn {
  // dyadContainerKernel always builds dyadic kernels — convert the
  // comprehensive Op to its Op2 equivalent for dispatch.
  const op2 = Op2.fromOp(operator) orelse return null;
  const xIsDict = comptime xk.isMap();
  const yIsDict = comptime yk.isMap();
  const xIsList = comptime (xk == .L);
  const yIsList = comptime (yk == .L);
  if (!(xIsDict or yIsDict or xIsList or yIsList)) return null;

  if (comptime xIsDict and yIsDict) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const dx = @field(x, @tagName(xk));
        const dy = @field(y, @tagName(yk));
        if (!dx.av().eq(dy.av())) return V{ .err = .length };
        const vals = dispatch.dispatch2(vm, op2, dx.bv(), dy.bv());
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(xk), Dict.init(vm.alloc, dx.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  if (comptime xIsDict) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const d = @field(x, @tagName(xk));
        const vals = dispatch.dispatch2(vm, op2, d.bv(), y);
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(xk), Dict.init(vm.alloc, d.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  if (comptime yIsDict) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const d = @field(y, @tagName(yk));
        const vals = dispatch.dispatch2(vm, op2, x, d.bv());
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(yk), Dict.init(vm.alloc, d.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  // at least one is L, neither is dict — element-wise with length broadcasting
  return &struct {
    fn k(vm: *VM, x: V, y: V) V {
      const xn = x.len();
      const yn = y.len();
      const n = if (xn == 1) yn else if (yn == 1) xn else if (xn == yn) xn else return V{ .err = .length };
      const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
      @memset(res.slice(), .blank);
      for (res.slice(), 0..) |*r, i| {
        const xv = if (xn == 1) x.ref() else x.at(i);
        defer xv.deinit(vm.alloc);
        const yv = if (yn == 1) y.ref() else y.at(i);
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
  }.k;
}

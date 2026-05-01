const std = @import("std");
const value = @import("../../noun/value.zig");
const VM = @import("../../runtime/vm.zig").VM;
const util = @import("../../util.zig");
const Op = @import("../../runtime/tape.zig").Op;
const dispatch = @import("../dispatch.zig");
const promote = @import("../promote.zig").promote;
const gpu = @import("../../gpu/gpu.zig");

// Threshold at which (.I, .I) elementwise dyads dispatch to the GPU
// when a backend is attached. Below this the kernel-launch + arena
// alloc overhead outweighs the win.
const DYAD_GPU_THRESHOLD: usize = 4096;

fn dyadOpForKOp(comptime op: Op) ?gpu.DyadOp {
  return switch (op) {
    .@"+" => .add,
    .@"-" => .sub,
    .@"*" => .mul,
    .@"%" => .div,
    .@"&" => .min,
    .@"|" => .max,
    else => null,
  };
}

fn monadOpForKOp(comptime op: Op) ?gpu.MonadOp {
  return switch (op) {
    .@"-"  => .neg,
    .abs   => .abs,
    else   => null,
  };
}

const V = value.V;
const K = @import("../../noun/class.zig").K;
const N = value.N;

pub const Attr = std.builtin.Type.StructField.Attributes;

pub const numeric_types    = [_]K{ .b, .i, .f, .B, .I, .F };
pub const arithmetic_types = [_]K{ .b, .i, .f, .B, .I, .F }; //, .L, .m, .M };

pub fn makeMonad(
  comptime operator: Op,
  comptime CastType: fn (type) type,
  comptime ResultType: fn (type) type,
  comptime Impl: type,
  comptime types: []const K,
) type {
  const op_default: Op = operator;
  comptime var names: []const []const u8 = &.{ "op" };
  comptime var field_types: []const type = &.{ Op };
  comptime var attrs: []const Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  inline for (types) |xk| {
    // const maybe: ?util.MonadFn = if (comptime xk.isNumeric())
    //   monadKernel(xk, CastType, ResultType, Impl)
    // else
    //   monadContainerKernel(xk, operator);
    const maybe: ?util.MonadFn = monadKernel(operator, xk, CastType, ResultType, Impl);
    if (maybe) |handler| {
      names = names ++ .{"_" ++ @tagName(xk)};
      field_types = field_types ++ .{util.MonadFn};
      const attr: Attr = .{ .default_value_ptr = @ptrCast(&handler) };
      attrs = attrs ++ .{attr};
    }
  }
  const n = names.len;
  return @Struct(.auto, null, names[0..n], &(field_types[0..n].*), &(attrs[0..n].*));
}

pub fn makeDyad(
  comptime operator: Op,
  comptime CastType: fn (type, type) type,
  comptime ResultType: fn (type, type) type,
  comptime Impl: type,
  comptime types: []const K,
) type {
  const op_default: Op = operator;
  comptime var names: []const []const u8 = &.{ "op" };
  comptime var field_types: []const type = &.{ Op };
  comptime var attrs: []const Attr = &.{
    .{ .default_value_ptr = @ptrCast(&op_default) },
  };
  inline for (types) |xk| {
    inline for (types) |yk| {
      // const maybe: ?util.DyadFn = if (comptime xk.isNumeric() and yk.isNumeric())
      //   dyadKernel(xk, yk, CastType, ResultType, Impl)
      // else
      //   dyadContainerKernel(xk, yk, operator);
      const maybe: ?util.DyadFn = dyadKernel(operator, xk, yk, CastType, ResultType, Impl);
      if (maybe) |handler| {
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
pub fn AlwaysFloat2(comptime _: type, comptime _: type) type { return f32; }
pub fn AlwaysBool2(comptime _: type, comptime _: type) type { return bool; }

pub fn Upcast1(comptime T: type) type { return if (T == f32) f32 else i32; }
pub fn AlwaysFloat1(comptime _: type) type { return f32; }
pub fn AlwaysInt1(comptime _: type) type { return i32; }
pub fn AlwaysBool1(comptime _: type) type { return bool; }

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
  comptime operator: Op,
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
    inline fn cast(v: anytype) C {
      const T = @TypeOf(v);
      if (T == C) return v;
      if (T == bool) return if (C == f32) (if (v) @as(f32, 1.0) else 0.0) else @intFromBool(v);
      if (T == i32 and C == f32) return @floatFromInt(v);
      if (T == f32 and C == i32) return @intFromFloat(v);
      unreachable;
    }
    fn kernel(vm: *VM, x: V) V {
      if (comptime xk.isAtom()) {
        const r: R = Impl.f(cast(@field(x, @tagName(xk))));
        return V.wrap(rk, r);
      }
      if (comptime xk.isVec()) {
        const vx = @field(x, @tagName(xk));
        // GPU dispatch: I or F monad with supported op, GPU-resident,
        // length above threshold, identity result kind.
        if (comptime (xk == .I or xk == .F) and rk == xk and monadOpForKOp(operator) != null) {
          if (vm.gpu) |g| if (vx.isGpu() and vx.ptr.len >= DYAD_GPU_THRESHOLD) {
            const n: u32 = @intCast(vx.ptr.len);
            const out_range = g.allocRange(n * @sizeOf(XT)) catch return V{ .err = .memory };
            const gop = comptime monadOpForKOp(operator).?;
            if (comptime xk == .I) g.monadI32(gop, out_range, vx.gpuRange(), n) catch return V{ .err = .memory }
            else g.monadF32(gop, out_range, vx.gpuRange(), n) catch return V{ .err = .memory };
            return @unionInit(V, @tagName(xk), N(XT).initGpu(g, out_range, n) catch return V{ .err = .memory });
          };
        }
        if (comptime R == XT and rk == xk) {
          if (vx.ptr.rc == 1) {
            for (vx.slice()) |*xv| xv.* = Impl.f(cast(xv.*));
            return x.ref();
          }
        }
        const out = N(R).init(vm.alloc, vx.ptr.len) catch return V{ .err = .memory };
        for (vx.slice(), out.slice()) |xv, *r| r.* = Impl.f(cast(xv));
        return @unionInit(V, @tagName(rk), out);
      }
      return V{ .err = .@"type" };
    }
  }.kernel;
}

fn dyadKernel(
  comptime operator: Op,
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
        const r: R = Impl.f(cast(@field(x, @tagName(xk))), cast(@field(y, @tagName(yk))));
        return V.wrap(rk, r);
      }
      if (comptime xk.isAtom() and yk.isVec()) {
        const xv = cast(@field(x, @tagName(xk)));
        const vy = @field(y, @tagName(yk));
        const out = N(R).init(vm.alloc, vy.ptr.len) catch return V{ .err = .memory };
        for (vy.slice(), out.slice()) |yv, *r| r.* = Impl.f(xv, cast(yv));
        return V.wrap(rk, out);
      }
      if (comptime xk.isVec() and yk.isAtom()) {
        const vx = @field(x, @tagName(xk));
        const yv = cast(@field(y, @tagName(yk)));
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
        // GPU dispatch: (.I, .I) or (.F, .F) elementwise on supported
        // ops, both operands GPU-resident, length above threshold.
        if (comptime xk == yk and (xk == .I or xk == .F) and dyadOpForKOp(operator) != null) {
          if (vm.gpu) |g| if (vx.isGpu() and vy.isGpu() and vx.ptr.len >= DYAD_GPU_THRESHOLD) {
            const n: u32 = @intCast(vx.ptr.len);
            const out_range = g.allocRange(n * @sizeOf(XT)) catch return V{ .err = .memory };
            const gop = comptime dyadOpForKOp(operator).?;
            if (comptime xk == .I) g.dyadI32(gop, out_range, vx.gpuRange(), vy.gpuRange(), n) catch return V{ .err = .memory }
            else g.dyadF32(gop, out_range, vx.gpuRange(), vy.gpuRange(), n) catch return V{ .err = .memory };
            return @unionInit(V, @tagName(xk), N(XT).initGpu(g, out_range, n) catch return V{ .err = .memory });
          };
        }
        if (comptime R == XT and rk == xk) {
          if (vx.ptr.rc == 1) {
            for (vx.slice(), vy.slice()) |*xv, yv| xv.* = Impl.f(cast(xv.*), cast(yv));
            return x.ref();
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

fn monadContainerKernel(
  comptime xk: K,
  comptime operator: Op,
) ?util.MonadFn {
  if (comptime xk == .L) {
    return &struct {
      fn k(vm: *VM, x: V) V {
        const n = x.L.ptr.len;
        const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
        @memset(res.slice(), .blank);
        for (res.slice(), 0..) |*r, i| {
          const elem = x.at(i);
          defer elem.deinit(vm.alloc);
          r.* = dispatch.dispatch1(vm, operator, elem);
          if (r.*.tag() == .err) return promote(vm.alloc, res) catch {
            (V{ .L = res }).deinit(vm.alloc);
            return V{ .err = .memory };
          };
        }
        return promote(vm.alloc, res) catch {
          (V{ .L = res }).deinit(vm.alloc);
          return V{ .err = .memory };
        };
      }
    }.k;
  }
  if (comptime xk == .m or xk == .M) {
    return &struct {
      fn k(vm: *VM, x: V) V {
        const d = @field(x, @tagName(xk));
        const vals = dispatch.dispatch1(vm, operator, d.bv());
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(xk), value.Dict.init(vm.alloc, d.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  return null;
}

fn dyadContainerKernel(
  comptime xk: K,
  comptime yk: K,
  comptime operator: Op,
) ?util.DyadFn {
  const xIsDict = comptime (xk == .m or xk == .M);
  const yIsDict = comptime (yk == .m or yk == .M);
  const xIsList = comptime (xk == .L);
  const yIsList = comptime (yk == .L);

  // dict op dict — keys must match, apply on values
  if (comptime xIsDict and yIsDict) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const dx = @field(x, @tagName(xk));
        const dy = @field(y, @tagName(yk));
        if (!dx.av().eq(dy.av())) return V{ .err = .length };
        const vals = dispatch.dispatch2(vm, operator, dx.bv(), dy.bv());
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(xk), value.Dict.init(vm.alloc, dx.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  // dict op numeric/list — apply on dict values
  if (comptime xIsDict and !yIsList) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const d = @field(x, @tagName(xk));
        const vals = dispatch.dispatch2(vm, operator, d.bv(), y);
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(xk), value.Dict.init(vm.alloc, d.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  // numeric op dict — apply on dict values
  if (comptime yIsDict and !xIsList) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const d = @field(y, @tagName(yk));
        const vals = dispatch.dispatch2(vm, operator, x, d.bv());
        if (vals.tag() == .err) return vals;
        return @unionInit(V, @tagName(yk), value.Dict.init(vm.alloc, d.av().ref(), vals) catch {
          vals.deinit(vm.alloc);
          return V{ .err = .memory };
        });
      }
    }.k;
  }
  // list op numeric/list — element-wise with broadcasting
  if (comptime xIsList and !yIsDict) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const xn = x.L.ptr.len;
        const yn = y.len();
        const n = if (xn == 1) yn else if (yn == 1) xn else if (xn == yn) xn else return V{ .err = .length };
        const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
        @memset(res.slice(), .blank);
        for (res.slice(), 0..) |*r, i| {
          const xv = if (xn == 1) x.ref() else x.at(i);
          defer xv.deinit(vm.alloc);
          const yv = if (yn == 1) y.ref() else y.at(i);
          defer yv.deinit(vm.alloc);
          r.* = dispatch.dispatch2(vm, operator, xv, yv);
          if (r.*.tag() == .err) return promote(vm.alloc, res) catch {
            (V{ .L = res }).deinit(vm.alloc);
            return V{ .err = .memory };
          };
        }
        return promote(vm.alloc, res) catch {
          (V{ .L = res }).deinit(vm.alloc);
          return V{ .err = .memory };
        };
      }
    }.k;
  }
  // numeric op list — element-wise with broadcasting
  if (comptime yIsList and !xIsDict) {
    return &struct {
      fn k(vm: *VM, x: V, y: V) V {
        const xn = x.len();
        const yn = y.L.ptr.len;
        const n = if (xn == 1) yn else if (yn == 1) xn else if (xn == yn) xn else return V{ .err = .length };
        const res = N(V).init(vm.alloc, n) catch return V{ .err = .memory };
        @memset(res.slice(), .blank);
        for (res.slice(), 0..) |*r, i| {
          const xv = if (xn == 1) x.ref() else x.at(i);
          defer xv.deinit(vm.alloc);
          const yv = if (yn == 1) y.ref() else y.at(i);
          defer yv.deinit(vm.alloc);
          r.* = dispatch.dispatch2(vm, operator, xv, yv);
          if (r.*.tag() == .err) return promote(vm.alloc, res) catch {
            (V{ .L = res }).deinit(vm.alloc);
            return V{ .err = .memory };
          };
        }
        return promote(vm.alloc, res) catch {
          (V{ .L = res }).deinit(vm.alloc);
          return V{ .err = .memory };
        };
      }
    }.k;
  }
  return null; // unsupported (e.g., list op dict)
}

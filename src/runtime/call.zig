const std = @import("std");
const value = @import("../noun/value.zig");
const V = value.V;
const opmod = @import("../noun/operator.zig");
const Fn = opmod.Fn;
const FnKind = opmod.FnKind;
const Op1 = opmod.Op1;
const Op2 = opmod.Op2;
const Op3 = opmod.Op3;
const Op4 = opmod.Op4;
const Adverb = opmod.Adverb;
const MAX_ARGS = opmod.MAX_ARGS;
const ArgMask = opmod.ArgMask;
const Partial = @import("../noun/partial.zig").Partial;
const VM = @import("vm.zig").VM;
const dispatch = @import("../primitive/dispatch.zig");
const derived_mod = @import("../primitive/derived.zig");
const amend_mod = @import("../primitive/amend.zig");
const syms = @import("syms.zig");

pub const CallMode = enum { sync, bracket };

pub const Call = struct {
  vm: *VM,

  pub fn apply(self: *Call, func: V, args: []const V, is_bracket: bool) V {
    return switch (func) {
      .o    => |ref| self.applyFn(ref, args, is_bracket),
      .p => |p|   self.applyPartial(p, args, is_bracket),
      .s       => |sym| syms.apply(self.vm, sym, args) catch V{ .err = .memory },
      .x       => |obj| self.applyExt(obj, args),
      .L, .I, .F, .S, .C, .B, .m, .M => {
        if (args.len == 1) return dispatch.dispatch2(self.vm, .@"@", func, args[0]);
        // Deep index: x[i;j;…] ≡ (…(x@i)@j…) — fold `@` across the path, the
        // same logic apply/`.` use, so a list or dict indexes at each depth.
        var res = func.ref();
        for (args) |a| {
          const next = dispatch.dispatch2(self.vm, .@"@", res, a);
          res.deinit(self.vm.alloc);
          if (next.tag() == .err) return next;
          res = next;
        }
        return res;
      },
      else => V{ .err = .@"type" },
    };
  }

  fn applyExt(_: *Call, obj: *@import("../noun/plugin.zig").ExtObj, args: []const V) V {
    return switch (args.len) {
      1 => if (obj.vtable.call1_fn) |f| f(obj.data, args[0]) else V{ .err = .@"type" },
      2 => if (obj.vtable.call2_fn) |f| f(obj.data, args[0], args[1]) else V{ .err = .@"type" },
      3 => if (obj.vtable.call3_fn) |f| f(obj.data, args[0], args[1], args[2]) else V{ .err = .@"type" },
      4 => if (obj.vtable.call4_fn) |f| f(obj.data, args[0], args[1], args[2], args[3]) else V{ .err = .@"type" },
      5 => if (obj.vtable.call5_fn) |f| f(obj.data, args[0], args[1], args[2], args[3], args[4]) else V{ .err = .@"type" },
      6 => if (obj.vtable.call6_fn) |f| f(obj.data, args[0], args[1], args[2], args[3], args[4], args[5]) else V{ .err = .@"type" },
      7 => if (obj.vtable.call7_fn) |f| f(obj.data, args[0], args[1], args[2], args[3], args[4], args[5], args[6]) else V{ .err = .@"type" },
      8 => if (obj.vtable.call8_fn) |f| f(obj.data, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]) else V{ .err = .@"type" },
      else => V{ .err = .rank },
    };
  }

  fn applyFn(self: *Call, ref: Fn, args: []const V, is_bracket: bool) V {
    var filled: usize = args.len;
    var has_gaps = false;
    if (is_bracket) {
      filled = 0;
      for (args) |a| if (!a.isNil()) { filled += 1; };
      has_gaps = filled < args.len;
    }
    switch (ref.kind) {
      .callable    => return self.applyCallable(ref, args, is_bracket, filled, has_gaps),
      .derived     => return self.applyDerivedFn(ref, args),
      .derived_data => {
        const entry = self.vm.fn_tables.derivedAt(@intCast(ref.idx));
        return derived_mod.derived(self.vm, entry.base, ref.getAdverb(), args, wrapper);
      },
      .train => {
        var buf: [7]u8 = undefined;
        const ops = ref.trainOps(&buf);
        if (args.len == 1) return self.applyTrain(ops, args[0]);
        return V{ .err = .rank };
      },
    }
  }

  fn applyCallable(self: *Call, ref: Fn, args: []const V, is_bracket: bool, filled: usize, has_gaps: bool) V {
    const vm = self.vm;
    const idx = ref.idx;

    if (opmod.isLambdaIdx(idx)) {
      const arity = ref.arity;
      // Over-application is a rank error, never a silent truncation. A niladic
      // takes one discarded argument (`{5}1` — the k way to call one), so the
      // ceiling is max(arity,1); `{x+y}[1;;3]` counts the gap and errors too.
      if (args.len > @max(arity, 1)) return V{ .err = .rank };
      if (has_gaps or (filled < arity and (is_bracket or filled > 0)))
        return makePartialFromArgs(vm, ref, args);
      return vm.callLambdaAndRun(ref, args);
    }

    const builtin_arity = ref.arity;
    if (has_gaps or (is_bracket and filled < builtin_arity))
      return makePartialFromArgs(vm, ref, args);

    if (opmod.isOp1Idx(idx)) {
      if (args.len == 1) return dispatch.dispatch1(vm, opmod.op1OfIdx(idx), args[0]);
      return V{ .err = .rank };
    }

    if (opmod.isOp2Idx(idx)) {
      const op2 = opmod.op2OfIdx(idx);
      if (args.len == 2) return dispatch.dispatch2(vm, op2, args[0], args[1]);
      if (args.len == 1) {
        if (opmod.op2ToOp1[@intFromEnum(op2)]) |op1|
          return dispatch.dispatch1(vm, op1, args[0]);
        return makePartialFromArgs(vm, ref, args);
      }
      return V{ .err = .rank };
    }

    if (opmod.isAdverbIdx(idx)) {
      if (args.len < builtin_arity) return makePartialFromArgs(vm, ref, args);
      const adv = opmod.adverbOfIdx(idx);
      if (args.len == 2) return derived_mod.derived(vm, args[0], adv, args[1..2], wrapper);
      if (args.len == 3) {
        const data_args = [_]V{ args[0], args[2] };
        return derived_mod.derived(vm, args[1], adv, &data_args, wrapper);
      }
      return V{ .err = .rank };
    }

    if (opmod.isOp3Idx(idx)) {
      if (args.len != 3) return V{ .err = .rank };
      var buf = [_]V{ args[0].ref(), args[1].ref(), args[2].ref() };
      defer for (&buf) |*v| v.deinit(vm.alloc);
      return switch (opmod.op3OfIdx(idx)) {
        .amend3 => amend_mod.amend(vm, &buf),
        .drill3 => amend_mod.dmend(vm, &buf),
        .splice3 => @import("../primitive/verb/splice.zig").splice(vm, buf[0], buf[1], buf[2]),
      };
    }

    if (opmod.isOp4Idx(idx)) {
      if (args.len != 4) return V{ .err = .rank };
      var buf = [_]V{ args[0].ref(), args[1].ref(), args[2].ref(), args[3].ref() };
      defer for (&buf) |*v| v.deinit(vm.alloc);
      return switch (opmod.op4OfIdx(idx)) {
        .amend4 => amend_mod.amend(vm, &buf),
        .drill4 => amend_mod.dmend(vm, &buf),
      };
    }

    return V{ .err = .rank };
  }

  fn applyDerivedFn(self: *Call, ref: Fn, args: []const V) V {
    return derived_mod.derived(self.vm, reconstructBaseV(ref.idx, ref.arity), ref.getAdverb(), args, wrapper);
  }

  fn applyPartial(self: *Call, p: *Partial, args: []const V, is_bracket: bool) V {
    const arity = p.arity;
    // More arguments than the projection has empty slots is a rank error —
    // the same rule as calling the underlying function directly.
    if (args.len > p.remaining()) return V{ .err = .rank };
    var merged: [MAX_ARGS]V = .{V.nil} ** MAX_ARGS;
    var fill: ArgMask = p.fill;
    for (0..arity) |i| {
      if (p.fill & (@as(ArgMask, 1) << @intCast(i)) != 0)
        merged[i] = p.args[i];
    }
    var inc: usize = 0;
    for (0..arity) |i| {
      if (fill & (@as(ArgMask, 1) << @intCast(i)) == 0 and inc < args.len) {
        merged[i] = args[inc];
        fill |= @as(ArgMask, 1) << @intCast(i);
        inc += 1;
      }
    }
    if (@popCount(fill) < arity)
      return makePartialFromMerged(self.vm, p.ref, arity, &merged, fill);
    return self.applyFn(p.ref, merged[0..arity], is_bracket);
  }

  fn applyTrain(self: *Call, ops: []const u8, arg: V) V {
    var res = arg.ref();
    var i: usize = ops.len;
    while (i > 0) {
      i -= 1;
      const op = Op1.fromString(ops[i .. i + 1]) orelse {
        res.deinit(self.vm.alloc);
        return .{ .err = .@"type" };
      };
      const next = dispatch.dispatch1(self.vm, op, res);
      res.deinit(self.vm.alloc);
      res = next;
    }
    return res;
  }

  pub fn wrapper(vm: *VM, f: V, a: []const V) V {
    var fc = Call{ .vm = vm };
    return fc.apply(f, a, false);
  }
};

/// Reconstruct a callable V from a global function index. Used when a .derived
/// Fn is dispatched and we need to hand the base to the adverb implementation.
fn reconstructBaseV(global_idx: u32, base_arity: u8) V {
  if (opmod.isLambdaIdx(global_idx)) {
    // Note: caller provides the cached arity since lambda table lookup
    // isn't available here without VM access.
    const lambda_idx = opmod.lambdaIdxOf(global_idx);
    return .{ .o = Fn.lambda(lambda_idx, base_arity) };
  }
  // Builtin: construct a Fn.callable directly with the global idx.
  return .{ .o = .{
    .kind = FnKind.callable,
    .arity = @intCast(opmod.arityOfBuiltin(global_idx)),
    .idx = @intCast(global_idx),
    .extra = 0,
  } };
}

pub fn applyDerivedBuiltin(vm: *VM, ref: Fn, args: []const V) V {
  const base = reconstructBaseV(ref.idx, ref.arity);
  return derived_mod.derived(vm, base, ref.getAdverb(), args, Call.wrapper);
}

/// Only the first `arity` slots are copied: slots above it can never be read
/// (their `fill` bit is 0, and `fill` is what deinit/format/apply walk), so the
/// per-partial cost tracks the function's arity rather than MAX_ARGS.
fn allocPartial(vm: *VM, ref: Fn, arity: u8, pa: *const [MAX_ARGS]V, fill: ArgMask) V {
  const p = vm.partials.create(vm.alloc) catch return V{ .err = .memory };
  p.pool = &vm.partials;
  p.rc = 1;
  p.fill = fill;
  p.arity = arity;
  p._pad = 0;
  p.ref = ref;
  for (0..arity) |i| p.args[i] = pa[i];
  return .{ .p = p };
}

pub fn makePartialFromArgs(vm: *VM, ref: Fn, args: []const V) V {
  const arity = ref.getRealArity();
  var pa: [MAX_ARGS]V = .{V.nil} ** MAX_ARGS;
  var fill: ArgMask = 0;
  for (args, 0..) |a, i| {
    if (i >= arity) break;
    if (!a.isNil()) { pa[i] = a.ref(); fill |= @as(ArgMask, 1) << @intCast(i); }
  }
  return allocPartial(vm, ref, arity, &pa, fill);
}

fn makePartialFromMerged(vm: *VM, ref: Fn, arity: u8, merged: *const [MAX_ARGS]V, fill: ArgMask) V {
  var pa: [MAX_ARGS]V = .{V.nil} ** MAX_ARGS;
  var new_fill: ArgMask = 0;
  for (0..arity) |i| {
    if (fill & (@as(ArgMask, 1) << @intCast(i)) != 0) {
      pa[i] = merged[i].ref();
      new_fill |= @as(ArgMask, 1) << @intCast(i);
    }
  }
  return allocPartial(vm, ref, arity, &pa, new_fill);
}

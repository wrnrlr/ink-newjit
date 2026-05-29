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
const Partial = @import("../noun/partial.zig").Partial;
const VM = @import("vm.zig").VM;
const dispatch = @import("../primitive/dispatch.zig");
const derived_mod = @import("../primitive/derived.zig");
const amend_mod = @import("../primitive/amend.zig");
const syms = @import("syms.zig");

pub const CallMode = enum { sync, bracket };

pub const Call = struct {
  vm: *VM,

  pub fn apply(self: *Call, func: V, args: []const V, is_bracket: bool) anyerror!V {
    return switch (func) {
      .func => |ref| try self.applyFn(ref, args, is_bracket),
      .partial => |p| try self.applyPartial(p, args, is_bracket),
      .s => |sym_idx| return try syms.apply(self.vm, sym_idx, args),
      .L, .I, .F, .S, .C, .B, .m, .M => {
        if (args.len == 1) return dispatch.dispatch2(self.vm, .@"@", func, args[0]);
        return V{ .err = .rank };
      },
      else => V{ .err = .@"type" },
    };
  }

  fn applyFn(self: *Call, ref: Fn, args: []const V, is_bracket: bool) anyerror!V {
    var filled: usize = args.len;
    var has_gaps = false;
    if (is_bracket) {
      filled = 0;
      for (args) |a| if (a != .blank) { filled += 1; };
      has_gaps = filled < args.len;
    }

    switch (ref.getKind()) {
      .callable => return self.applyCallable(ref, args, is_bracket, filled, has_gaps),
      .derived => return self.applyDerivedFn(ref, args),
      .derived_data => {
        const entry = self.vm.fn_tables.derivedAt(@intCast(ref.idx));
        return derived_mod.derived(self.vm, entry.base, ref.getAdverb(), args, wrapper);
      },
      .train => {
        var buf: [7]u8 = undefined;
        const ops = ref.trainOps(&buf);
        if (args.len == 1) return try self.applyTrain(ops, args[0]);
        return V{ .err = .rank };
      },
    }
  }

  // Unified dispatch for any callable (builtin verb / adverb / lambda).
  // Range-checks `ref.idx` to pick the right execution path.
  fn applyCallable(self: *Call, ref: Fn, args: []const V, is_bracket: bool, filled: usize, has_gaps: bool) anyerror!V {
    const vm = self.vm;
    const idx = ref.idx;

    // User-defined lambda: idx ≥ BUILTIN_COUNT
    if (opmod.isLambdaIdx(idx)) {
      const arity = ref.arity;
      if (has_gaps or (filled < arity and (is_bracket or filled > 0)))
        return makePartialFromArgs(vm, ref, args);
      const prev_frames = vm.frames_len;
      const res_slot = vm.stack_len;
      try vm.push(.blank);
      for (args) |arg| try vm.push(arg.ref());
      try vm.callLambda(ref, args.len, res_slot);
      try vm.runUntil(prev_frames);
      return vm.pop();
    }

    // Builtin verb or adverb: dispatch by idx range.
    const builtin_arity = ref.arity;

    // Partial-application check: bracket form with missing/blank args.
    if (has_gaps or (is_bracket and filled < builtin_arity))
      return makePartialFromArgs(vm, ref, args);

    // Op1 (monadic verb)
    if (opmod.isOp1Idx(idx)) {
      if (args.len == 1) return dispatch.dispatch1(vm, opmod.op1OfIdx(idx), args[0]);
      return V{ .err = .rank };
    }

    // Op2 (dyadic verb) — polymorphic: 1-arg call falls back to Op1 equivalent.
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

    // Standalone adverb (e.g. `\[base; arg]` or `\[seed; base; arg]`).
    if (opmod.isAdverbIdx(idx)) {
      if (args.len < builtin_arity) return makePartialFromArgs(vm, ref, args);
      const adv = opmod.adverbOfIdx(idx);
      // 2 args = monogram form: derived(base, [arg]).
      if (args.len == 2) return derived_mod.derived(vm, args[0], adv, args[1..2], wrapper);
      // 3 args = digram form: derived(base, [extra, arg]).
      if (args.len == 3) {
        const data_args = [_]V{ args[0], args[2] };
        return derived_mod.derived(vm, args[1], adv, &data_args, wrapper);
      }
      return V{ .err = .rank };
    }

    // Op3 (triadic builtin: amend3 / drill3)
    if (opmod.isOp3Idx(idx)) {
      if (args.len != 3) return V{ .err = .rank };
      var buf = [_]V{ args[0].ref(), args[1].ref(), args[2].ref() };
      defer for (&buf) |*v| v.deinit(vm.alloc);
      return switch (opmod.op3OfIdx(idx)) {
        .amend3 => try amend_mod.amend(vm, &buf),
        .drill3 => try amend_mod.dmend(vm, &buf),
      };
    }

    // Op4 (tetradic builtin: amend4 / drill4)
    if (opmod.isOp4Idx(idx)) {
      if (args.len != 4) return V{ .err = .rank };
      const op4 = opmod.op4OfIdx(idx);
      var buf = [_]V{ args[0].ref(), args[1].ref(), args[2].ref(), args[3].ref() };
      defer for (&buf) |*v| v.deinit(vm.alloc);
      return switch (op4) {
        .amend4 => try amend_mod.amend(vm, &buf),
        .drill4 => try amend_mod.dmend(vm, &buf),
      };
    }

    return V{ .err = .rank };
  }

  // Apply a .derived Fn (base callable + adverb).
  fn applyDerivedFn(self: *Call, ref: Fn, args: []const V) anyerror!V {
    const base_idx = ref.idx;
    const adv = ref.getAdverb();
    const base = reconstructBaseV(base_idx, ref.arity);
    return derived_mod.derived(self.vm, base, adv, args, wrapper);
  }

  fn applyPartial(self: *Call, p: *Partial, args: []const V, is_bracket: bool) anyerror!V {
    const arity = p.arity;
    var merged: [8]V = .{.blank} ** 8;
    var fill: u8 = p.fill;
    for (0..arity) |i| {
      if (p.fill & (@as(u8, 1) << @intCast(i)) != 0)
        merged[i] = p.args[i];
    }
    var inc: usize = 0;
    for (0..arity) |i| {
      if (fill & (@as(u8, 1) << @intCast(i)) == 0 and inc < args.len) {
        merged[i] = args[inc];
        fill |= @as(u8, 1) << @intCast(i);
        inc += 1;
      }
    }
    const filled: u8 = @popCount(fill);
    if (filled < arity or (is_bracket and arity == 2 and filled == 1 and p.isFull()))
      return makePartialFromMerged(self.vm, p.ref, arity, &merged, fill);
    return try self.applyFn(p.ref, merged[0..arity], is_bracket);
  }

  fn applyTrain(self: *Call, ops: []const u8, arg: V) anyerror!V {
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
    return fc.apply(f, a, false) catch V{ .err = .memory };
  }
};

/// Reconstruct a callable V from a global function index. Used when a .derived
/// Fn is dispatched and we need to hand the base to the adverb implementation.
fn reconstructBaseV(global_idx: u32, base_arity: u8) V {
  if (opmod.isLambdaIdx(global_idx)) {
    // Note: caller provides the cached arity since lambda table lookup
    // isn't available here without VM access.
    const lambda_idx = opmod.lambdaIdxOf(global_idx);
    return .{ .func = Fn.lambda(lambda_idx, base_arity) };
  }
  // Builtin: construct a Fn.callable directly with the global idx.
  return .{ .func = .{
    .kind = @intFromEnum(FnKind.callable),
    .arity = @intCast(opmod.arityOfBuiltin(global_idx)),
    .idx = @intCast(global_idx),
    .extra = 0,
  } };
}

pub fn applyDerivedBuiltin(vm: *VM, ref: Fn, args: []const V) V {
  const base = reconstructBaseV(ref.idx, ref.arity);
  return derived_mod.derived(vm, base, ref.getAdverb(), args, Call.wrapper);
}

fn makePartialFromArgs(vm: *VM, ref: Fn, args: []const V) !V {
  const arity = ref.getRealArity();
  var pa: [8]V = .{.blank} ** 8;
  var fill: u8 = 0;
  for (args, 0..) |a, i| {
    if (i >= arity) break;
    if (a != .blank) { pa[i] = a.ref(); fill |= @as(u8, 1) << @intCast(i); }
  }
  const p = try vm.partial_pool.create(vm.alloc);
  p.* = .{ .pool = &vm.partial_pool, .rc = 1, .fill = fill, .arity = arity, ._pad = 0, .ref = ref, .args = pa };
  return .{ .partial = p };
}

fn makePartialFromMerged(vm: *VM, ref: Fn, arity: u8, merged: *const [8]V, fill: u8) !V {
  var args: [8]V = .{.blank} ** 8;
  var new_fill: u8 = 0;
  for (0..arity) |i| {
    if (fill & (@as(u8, 1) << @intCast(i)) != 0) {
      args[i] = merged[i].ref();
      new_fill |= @as(u8, 1) << @intCast(i);
    }
  }
  const p = try vm.partial_pool.create(vm.alloc);
  p.* = .{ .pool = &vm.partial_pool, .rc = 1, .fill = new_fill, .arity = arity, ._pad = 0, .ref = ref, .args = args };
  return .{ .partial = p };
}

const std = @import("std");
const value = @import("../noun/value.zig");
const V = value.V;
const opmod = @import("../noun/operator.zig");
const Fn = opmod.Fn;
const FnKind = opmod.FnKind;
const Op1 = opmod.Op1;
const Op2 = opmod.Op2;
const Partial = @import("../noun/partial.zig").Partial;
const Adverb = opmod.Adverb;
const VM = @import("vm.zig").VM;
const dispatch = @import("../primitive/dispatch.zig");
const derived = @import("../primitive/derived.zig").derived;
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
    // In bracket calls, blank args are gaps (partial application markers)
    var filled: usize = args.len;
    var has_gaps = false;
    if (is_bracket) {
      filled = 0;
      for (args) |a| if (a != .blank) { filled += 1; };
      has_gaps = filled < args.len;
    }

    switch (ref.getKind()) {
      .builtin => {
        if (ref.arity == 1) {
          if (args.len == 1) return dispatch.dispatch1(self.vm, ref.getOp1(), args[0]);
          return .{ .err = .rank };
        }
        // arity == 2 (dyadic)
        const op2 = ref.getOp2();
        if (has_gaps or (is_bracket and filled < ref.arity))
          return makePartialFromArgs(self.vm, ref, args);
        if (args.len == 1) {
          // polymorphic: dyad called with one arg → monadic equivalent if any
          if (opmod.op2ToOp1[@intFromEnum(op2)]) |op1| {
            return dispatch.dispatch1(self.vm, op1, args[0]);
          }
          return makePartialFromArgs(self.vm, ref, args);
        }
        if (args.len == 2) return dispatch.dispatch2(self.vm, op2, args[0], args[1]);
        return .{ .err = .rank };
      },
      .lambda => {
        const arity = ref.getRealArity();
        if (has_gaps or (filled < arity and (is_bracket or filled > 0)))
          return makePartialFromArgs(self.vm, ref, args);
        const prev_frames = self.vm.frames_len;
        const res_slot = self.vm.stack_len;
        try self.vm.push(.blank);
        for (args) |arg| try self.vm.push(arg.ref());
        try self.vm.callLambda(ref, args.len, res_slot);
        try self.vm.runUntil(prev_frames);
        return self.vm.pop();
      },
      .adverb => {
        if (args.len == 1) {
          const adv = ref.getAdverb();
          const base_v = args[0];
          if (base_v != .func) return V{ .err = .@"type" };
          const base_ref = base_v.func;
          const derived_ref = switch (base_ref.getKind()) {
            .builtin => if (base_ref.arity == 1) Fn.makeDerivedMonad(base_ref.getOp1(), adv)
                        else Fn.makeDerivedDyad(base_ref.getOp2(), adv),
            .lambda  => Fn.makeDerivedLambda(@intCast(base_ref.idx), adv),
            else => blk: {
              const idx = try self.vm.fn_tables.addDerived(.{ .base = V{ .func = base_ref }, .adverb = adv });
              break :blk Fn.makeDerivedTable(idx);
            },
          };
          return .{ .func = derived_ref };
        }
        return .{ .err = .rank };
      },
      .derived_builtin => {
        const base = V{ .func = if (ref.arity == 1) Fn.monad(ref.getOp1()) else Fn.dyad(ref.getOp2()) };
        return derived(self.vm, base, ref.getAdverb(), args, wrapper);
      },
      .derived_lambda => {
        const lambda_ref = Fn.lambda(@intCast(ref.idx), self.vm.fn_tables.lambdaAt(@intCast(ref.idx)).arity);
        const base = V{ .func = lambda_ref };
        return derived(self.vm, base, ref.getAdverb(), args, wrapper);
      },
      .derived_table => {
        const entry = self.vm.fn_tables.derivedAt(@intCast(ref.idx));
        return derived(self.vm, entry.base, entry.adverb, args, wrapper);
      },
      .train => {
        var buf: [7]u8 = undefined;
        const ops = ref.trainOps(&buf);
        if (args.len == 1) return try self.applyTrain(ops, args[0]);
        return V{ .err = .rank };
      },
    }
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
      // Trains are single-char monadic-context glyphs; lookup in Op1.
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

  fn wrapper(vm: *VM, f: V, a: []const V) V {
    var fc = Call{ .vm = vm };
    return fc.apply(f, a, false) catch V{ .err = .memory };
  }
};

pub fn applyDerivedBuiltin(vm: *VM, ref: Fn, args: []const V) V {
  const base = V{ .func = if (ref.arity == 1) Fn.monad(ref.getOp1()) else Fn.dyad(ref.getOp2()) };
  return derived(vm, base, ref.getAdverb(), args, Call.wrapper);
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

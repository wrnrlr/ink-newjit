const std = @import("std");
const K = @import("../noun/class.zig").K;
const Op1 = @import("../noun/operator.zig").Op1;
const Op2 = @import("../noun/operator.zig").Op2;
const xfer = @import("../primitive/verb/transfer.zig");

// ─── Stencil catalog ──────────────────────────────────────────────────────────
//
// A *stencil* is a monomorphic verb instance: a fixed verb applied to fixed
// operand classes producing a fixed result class — e.g. `(+, I, I) → I`. This is
// the unit a copy-and-patch JIT compiles to a machine-code template, and the
// unit type inference selects: an `Apply2` whose operands infer to concrete
// classes maps to exactly one stencil (or none → stay on dynamic dispatch).
//
// The catalog is the set of implemented monomorphic numeric kernels, which is
// precisely the non-`blank` domain of the inference transfer tables (`rty_dyad`/
// `rty_monad`). Deriving it from those tables — rather than a separate list —
// keeps the JIT's stencil set, the inference engine, and the runtime dispatch
// kernels all sourced from the one comptime `Dyads`/`Monads` definition.

pub const NONE: u16 = 0xffff;

pub const DyadStencil = struct { op: Op2, x: K, y: K, out: K };
pub const MonadStencil = struct { op: Op1, x: K, out: K };

fn allK() [K.COUNT]K {
  var ks: [K.COUNT]K = undefined;
  for (std.meta.fields(K), 0..) |f, i| ks[i] = @enumFromInt(f.value);
  return ks;
}

pub const dyad_stencils: []const DyadStencil = blk: {
  @setEvalBranchQuota(10_000_000);
  var list: []const DyadStencil = &.{};
  for (allK()) |xk| {
    for (allK()) |yk| {
      for (std.meta.fields(Op2)) |opf| {
        const op: Op2 = @enumFromInt(opf.value);
        const out = xfer.rty_dyad[op.code()][xk.code()][yk.code()];
        if (out != .blank) list = list ++ .{DyadStencil{ .op = op, .x = xk, .y = yk, .out = out }};
      }
    }
  }
  break :blk list;
};

pub const monad_stencils: []const MonadStencil = blk: {
  @setEvalBranchQuota(10_000_000);
  var list: []const MonadStencil = &.{};
  for (allK()) |xk| {
    for (std.meta.fields(Op1)) |opf| {
      const op: Op1 = @enumFromInt(opf.value);
      const out = xfer.rty_monad[op.code()][xk.code()];
      if (out != .blank) list = list ++ .{MonadStencil{ .op = op, .x = xk, .out = out }};
    }
  }
  break :blk list;
};

// Reverse lookup tables: (op, classes) → stencil id, or NONE.
const dyad_id: [Op2.COUNT][K.COUNT][K.COUNT]u16 = blk: {
  @setEvalBranchQuota(10_000_000);
  var t: [Op2.COUNT][K.COUNT][K.COUNT]u16 = undefined;
  for (&t) |*plane| for (plane) |*row| for (row) |*cell| {
    cell.* = NONE;
  };
  for (dyad_stencils, 0..) |s, i| t[s.op.code()][s.x.code()][s.y.code()] = @intCast(i);
  break :blk t;
};

const monad_id: [Op1.COUNT][K.COUNT]u16 = blk: {
  @setEvalBranchQuota(10_000_000);
  var t: [Op1.COUNT][K.COUNT]u16 = undefined;
  for (&t) |*row| for (row) |*cell| {
    cell.* = NONE;
  };
  for (monad_stencils, 0..) |s, i| t[s.op.code()][s.x.code()] = @intCast(i);
  break :blk t;
};

/// Stencil id for a dyad applied to concrete operand classes, or null.
pub fn selectDyad(op: Op2, xk: K, yk: K) ?u16 {
  const id = dyad_id[op.code()][xk.code()][yk.code()];
  return if (id == NONE) null else id;
}

/// Stencil id for a monad applied to a concrete operand class, or null.
pub fn selectMonad(op: Op1, xk: K) ?u16 {
  const id = monad_id[op.code()][xk.code()];
  return if (id == NONE) null else id;
}

pub fn dyad(id: u16) DyadStencil {
  return dyad_stencils[id];
}
pub fn monad(id: u16) MonadStencil {
  return monad_stencils[id];
}

// ─── tests ────────────────────────────────────────────────────────────────────

test "catalog covers the arithmetic core" {
  // scalar and vector add, division-to-float, comparison-to-bool.
  try std.testing.expectEqual(@as(K, .i), dyad(selectDyad(.@"+", .i, .i).?).out);
  try std.testing.expectEqual(@as(K, .I), dyad(selectDyad(.@"+", .I, .I).?).out);
  try std.testing.expectEqual(@as(K, .f), dyad(selectDyad(.@"+", .i, .f).?).out);
  try std.testing.expectEqual(@as(K, .f), dyad(selectDyad(.@"%", .i, .i).?).out);
  try std.testing.expectEqual(@as(K, .b), dyad(selectDyad(.@"<", .i, .i).?).out);
  try std.testing.expectEqual(@as(K, .f), monad(selectMonad(.sqrt, .f).?).out);
}

test "non-numeric operands have no stencil" {
  try std.testing.expectEqual(@as(?u16, null), selectDyad(.@"+", .s, .s));
  try std.testing.expectEqual(@as(?u16, null), selectDyad(.@"+", .L, .i));
}

test "every catalogued stencil round-trips through its id" {
  for (dyad_stencils, 0..) |s, i| {
    try std.testing.expectEqual(@as(?u16, @intCast(i)), selectDyad(s.op, s.x, s.y));
  }
  try std.testing.expect(dyad_stencils.len > 0);
  try std.testing.expect(monad_stencils.len > 0);
}

const std = @import("std");
const K = @import("../../noun/class.zig").K;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const verbs = @import("verbs.zig");
const h = @import("helper.zig");

// ─── Verb type-transfer tables ────────────────────────────────────────────────
//
// `rty_dyad[op][xk][yk]` / `rty_monad[op][xk]` give the *result class* a verb
// produces for fully-known operand classes — the static counterpart of the
// runtime `dyad_table` / `monad_table` dispatch. They are emitted at comptime
// from the SAME `Dyads`/`Monads` metadata that builds the dispatch tables, so
// the inference pass and the interpreter can never disagree about result types.
//
// Indexed by `K.code()` (vectors remapped) and `Op*.code()`, matching the
// runtime tables. A `.blank` entry means "no precise transfer" — either the slot
// is unimplemented, or the verb's result is data-dependent (a `.custom` verb such
// as `,` `#` `@` whose partial transfer lives in infer.zig). Inference treats
// `.blank` as ⊤ and falls back to dynamic dispatch.
//
// The element-type math (`Upcast2`/`Float2`/…) is imported from helper.zig, not
// duplicated. Only the per-verb *strategy association* lives here, and the
// `transfer table matches kernels` test locks it to the real kernels forever.

const BLANK: K = .blank;

/// Result-type strategy for a dyadic verb, keyed by its `Dyads` decl name.
/// Returns null for data-dependent / non-numeric verbs (handled as `.custom`).
fn dyadStrategy(comptime name: []const u8) ?fn (type, type) type {
  const eq = std.mem.eql;
  if (eq(u8, name, "N+N")) return h.Upcast2;
  if (eq(u8, name, "N-N")) return h.Upcast2;
  if (eq(u8, name, "N*N")) return h.Upcast2;
  if (eq(u8, name, "N%N")) return h.Float2;
  if (eq(u8, name, "N&N")) return h.Upcast2;
  if (eq(u8, name, "N|N")) return h.Upcast2;
  if (eq(u8, name, "B&B")) return h.Bool2;
  if (eq(u8, name, "B|B")) return h.Bool2;
  if (eq(u8, name, "X=X")) return h.Bool2;
  if (eq(u8, name, "X<X")) return h.Bool2;
  if (eq(u8, name, "X>X")) return h.Bool2;
  if (eq(u8, name, "I⌊I")) return h.Int2;
  if (eq(u8, name, "I÷I")) return h.Int2;
  return null;
}

/// Result-type strategy for an element-preserving monadic verb, keyed by its
/// `Monads` decl name. Reductions and structural verbs return null (custom).
fn monadStrategy(comptime name: []const u8) ?fn (type) type {
  const eq = std.mem.eql;
  if (eq(u8, name, "-N")) return h.Upcast1;
  if (eq(u8, name, "~x")) return h.Bool1;
  if (eq(u8, name, "sqrt")) return h.Float1;
  if (eq(u8, name, "exp")) return h.Float1;
  if (eq(u8, name, "log")) return h.Float1;
  if (eq(u8, name, "sin")) return h.Float1;
  if (eq(u8, name, "cos")) return h.Float1;
  if (eq(u8, name, "sqr")) return h.Upcast1;
  if (eq(u8, name, "abs")) return h.Upcast1;
  if (eq(u8, name, "_n")) return h.Int1;
  return null;
}

fn numericish(k: K) bool {
  return K.isNumeric(k);
}

pub const rty_dyad: [Op2.COUNT][K.COUNT][K.COUNT]K = blk: {
  @setEvalBranchQuota(10_000_000);
  var t: [Op2.COUNT][K.COUNT][K.COUNT]K = undefined;
  for (&t) |*plane| for (plane) |*row| for (row) |*cell| {
    cell.* = BLANK;
  };
  // Iterate declarations in source order so &/| numeric→bool overrides land in
  // the same order the runtime dispatch table applies them.
  for (std.meta.declarations(verbs.Dyads)) |decl| {
    const Verb = @field(verbs.Dyads, decl.name);
    const op = verbs.opOf(Verb, Op2) orelse continue;
    const strat = dyadStrategy(decl.name) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = verbs.parseSig(f.name);
      if (sig.len != 2) continue;
      if (!numericish(sig[0]) or !numericish(sig[1])) continue;
      t[op.code()][sig[0].code()][sig[1].code()] = h.resultKind2(sig[0], sig[1], strat);
    }
  }
  break :blk t;
};

pub const rty_monad: [Op1.COUNT][K.COUNT]K = blk: {
  @setEvalBranchQuota(10_000_000);
  var t: [Op1.COUNT][K.COUNT]K = undefined;
  for (&t) |*row| for (row) |*cell| {
    cell.* = BLANK;
  };
  for (std.meta.declarations(verbs.Monads)) |decl| {
    const Verb = @field(verbs.Monads, decl.name);
    const op = verbs.opOf(Verb, Op1) orelse continue;
    const strat = monadStrategy(decl.name) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = verbs.parseSig(f.name);
      if (sig.len != 1) continue;
      if (!numericish(sig[0])) continue;
      t[op.code()][sig[0].code()] = h.resultKind1(sig[0], strat);
    }
  }
  break :blk t;
};

/// Look up a dyadic result class; returns null when there is no precise transfer.
pub fn dyadResult(op: Op2, xk: K, yk: K) ?K {
  const r = rty_dyad[op.code()][xk.code()][yk.code()];
  return if (r == .blank) null else r;
}

/// Look up a monadic result class; returns null when there is no precise transfer.
pub fn monadResult(op: Op1, xk: K) ?K {
  const r = rty_monad[op.code()][xk.code()];
  return if (r == .blank) null else r;
}

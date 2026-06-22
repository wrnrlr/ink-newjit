const std = @import("std");
const ir = @import("../ir.zig");
const tymod = @import("type.zig");
const Ty = tymod.Ty;
const Elem = tymod.Elem;
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const xfer = @import("../../primitive/verb/transfer.zig");
const stencil = @import("../../jit/stencil.zig");

// ─── Type-inference pass ──────────────────────────────────────────────────────
//
// A forward dataflow abstract interpretation over the IR. Each instruction's
// `ty` starts at ⊥ and is repeatedly recomputed from its inputs and joined in,
// climbing the lattice until a fixpoint. The element+rank lattice has finite
// height, so this always terminates; inputs almost always precede their
// consumer, so it converges in one or two sweeps. The pass only writes
// `inst.ty` — it never changes anything `lower()` reads, so emitted bytecode is
// unaffected.
//
// Phase 1 scope: literals, Apply1/Apply2 numeric chains, reductions, and `$[…]`
// branch merges are inferred precisely. Locals, globals, calls, and structural
// verbs degrade to ⊤ (dynamic dispatch) — see the `else` arms below.

const MAX_SLOTS = 256;

/// Per-scope local-slot typing. A local's type is the join of every value
/// assigned to its slot — an over-approximation, so a read gets a concrete class
/// only when *all* writers agree on it (then the runtime value is certainly that
/// class). Slots that are never assigned in this scope (lambda args, externals)
/// are ⊤. Lambdas don't capture scope, so a slot's only writers are this scope's
/// `AssignLocal`s, which makes the join sound. Globals stay ⊤ (cross-scope).
const Locals = struct {
  ty: [MAX_SLOTS]Ty = .{Ty.BOTTOM} ** MAX_SLOTS,
  assigned: [MAX_SLOTS]bool = .{false} ** MAX_SLOTS,

  fn read(self: *const Locals, slot: usize) Ty {
    if (slot >= MAX_SLOTS or !self.assigned[slot]) return Ty.TOP;
    return self.ty[slot];
  }
  fn write(self: *Locals, slot: usize, t: Ty) void {
    if (slot >= MAX_SLOTS) return;
    self.ty[slot] = self.ty[slot].join(t);
  }
};

pub fn inferTypes(scope_ir: *ir.IR) void {
  const insts = scope_ir.instructions.items;
  const n = insts.len;
  if (n == 0) return;
  var locals = Locals{};
  for (insts) |inst| {
    if (inst.op == .AssignLocal and inst.arg1 < MAX_SLOTS) locals.assigned[inst.arg1] = true;
  }
  // Finite-height lattice ⇒ bounded passes; the cap also guards back-edges.
  const max_passes = n + 4;
  var pass: usize = 0;
  var changed = true;
  while (changed and pass < max_passes) : (pass += 1) {
    changed = false;
    for (insts) |*inst| {
      if (inst.is_dead) continue;
      const computed = switch (inst.op) {
        .Local, .LocalLast => locals.read(inst.arg1),
        .AssignLocal => blk: {
          const t = inputTy(scope_ir, inst.*, 0);
          locals.write(inst.arg1, t);
          break :blk t;
        },
        else => transfer(scope_ir, inst.*),
      };
      const next = inst.ty.join(computed);
      if (!tyEql(next, inst.ty)) {
        inst.ty = next;
        changed = true;
      }
    }
  }
}

/// Stencil selection: after types are known, tag each `Apply1`/`Apply2` whose
/// operands infer to concrete classes with the monomorphic stencil that would
/// serve it. `inst.stencil` stays `NONE` when any operand is dynamic — that
/// instruction keeps the runtime polymorphic dispatch. This is the JIT/codegen
/// hand-off: the IR now carries which calls can be specialized and into what.
pub fn selectStencils(scope_ir: *ir.IR) void {
  const insts = scope_ir.instructions.items;
  for (insts) |*inst| {
    if (inst.is_dead) continue;
    switch (inst.op) {
      .Apply1 => {
        const xk = inputTy(scope_ir, inst.*, 0).toK() orelse continue;
        const op: Op1 = @enumFromInt(@as(u8, @intCast(inst.arg1)));
        if (stencil.selectMonad(op, xk)) |id| inst.stencil = id;
      },
      .Apply2 => {
        const xk = inputTy(scope_ir, inst.*, 0).toK() orelse continue;
        const yk = inputTy(scope_ir, inst.*, 1).toK() orelse continue;
        const op: Op2 = @enumFromInt(@as(u8, @intCast(inst.arg1)));
        if (stencil.selectDyad(op, xk, yk)) |id| inst.stencil = id;
      },
      else => {},
    }
  }
}

fn transfer(scope_ir: *ir.IR, inst: ir.IRInst) Ty {
  return switch (inst.op) {
    .Const => if (inst.val) |v| fromValue(v) else Ty.TOP,
    .Int => Ty.atom(.i),
    .Apply1 => blk: {
      const xt = inputTy(scope_ir, inst, 0);
      break :blk transferMonad(@enumFromInt(@as(u8, @intCast(inst.arg1))), xt);
    },
    .Apply2 => blk: {
      const xt = inputTy(scope_ir, inst, 0);
      const yt = inputTy(scope_ir, inst, 1);
      break :blk transferDyad(@enumFromInt(@as(u8, @intCast(inst.arg1))), xt, yt);
    },
    .Nop => joinInputs(scope_ir, inst), // `$[…]` branch merge
    else => Ty.TOP,
  };
}

fn inputTy(scope_ir: *ir.IR, inst: ir.IRInst, idx: usize) Ty {
  if (inst.inputs.len <= idx) return Ty.BOTTOM;
  const id = inst.inputs[idx];
  if (id == ir.NO_VALUE or id >= scope_ir.instructions.items.len) return Ty.TOP;
  return scope_ir.instructions.items[id].ty;
}

fn joinInputs(scope_ir: *ir.IR, inst: ir.IRInst) Ty {
  var acc: Ty = Ty.BOTTOM;
  for (inst.inputs) |id| {
    if (id == ir.NO_VALUE or id >= scope_ir.instructions.items.len) return Ty.TOP;
    acc = acc.join(scope_ir.instructions.items[id].ty);
  }
  return acc;
}

// ─── per-verb transfer ────────────────────────────────────────────────────────

fn transferMonad(op: Op1, xt: Ty) Ty {
  if (xt.isBottom()) return Ty.BOTTOM;
  switch (op) {
    .@"+/", .@"*/" => return reduceTy(xt, true), // sum/product: bool promotes to int
    .@"|/", .@"&/" => return reduceTy(xt, false), // max/min: element preserved
    .count => return Ty.atom(.i), // tally
    .@":" => return xt, // identity
    .@"!" => {
      // monadic `!`: iota on an int → int-vector; keys of a dict/table → symbols.
      if (xt.elem == .i and xt.rank == 0) return Ty.vector(.i, null);
      if (xt.elem == .dict or xt.elem == .table) return Ty.vector(.s, null);
      return Ty.TOP;
    },
    else => {},
  }
  const xk = xt.toK() orelse return Ty.TOP;
  const rk = xfer.monadResult(op, xk) orelse return Ty.TOP;
  // Element-preserving (resultKind1 keeps the container): keep rank/shape, swap element.
  var t = xt;
  t.elem = elemOfK(rk);
  return t;
}

fn transferDyad(op: Op2, xt: Ty, yt: Ty) Ty {
  if (xt.isBottom() or yt.isBottom()) return Ty.BOTTOM;
  if (op == .@",") return concatTy(xt, yt);
  const xk = xt.toK() orelse return Ty.TOP;
  const yk = yt.toK() orelse return Ty.TOP;
  const rk = xfer.dyadResult(op, xk, yk) orelse return Ty.TOP;
  return broadcastTy(rk, xt, yt);
}

/// Elementwise dyad result: element/rank come from `rk`; shape from the vector
/// operand(s), joined when both are vectors.
fn broadcastTy(rk: K, xt: Ty, yt: Ty) Ty {
  var t = Ty.fromK(rk, null);
  if (t.rank == 1) {
    if (xt.rank == 1 and yt.rank == 1) {
      t.shape[0] = xt.shape[0].join(yt.shape[0]);
    } else if (xt.rank == 1) {
      t.shape[0] = xt.shape[0];
    } else if (yt.rank == 1) {
      t.shape[0] = yt.shape[0];
    }
  }
  return t;
}

/// Reduction collapses rank by one. `+/`,`*/` promote bool→int; `|/`,`&/` keep
/// the element type. Length is data-dependent, so the result shape is unknown.
fn reduceTy(xt: Ty, promote_bool: bool) Ty {
  if (xt.rank == tymod.RANK_TOP) return Ty.TOP;
  if (xt.rank == 0) return xt; // reducing an atom is a no-op
  var e = xt.elem;
  if (promote_bool and e == .b) e = .i;
  return .{ .elem = e, .rank = xt.rank - 1 };
}

/// `,` (concat/enlist): rank-1 result whose element is the numeric join of the
/// operands' elements. Length is left unknown in Phase 1.
fn concatTy(xt: Ty, yt: Ty) Ty {
  const e = joinElem(xt.elem, yt.elem);
  return .{ .elem = e, .rank = 1 };
}

// ─── helpers ──────────────────────────────────────────────────────────────────

fn fromValue(v: V) Ty {
  const k = v.tag();
  const length: ?u32 = if (k.isVec()) @intCast(v.len()) else null;
  return Ty.fromK(k, length);
}

fn elemOfK(k: K) Elem {
  return switch (k) {
    .b, .B => .b,
    .i, .I => .i,
    .f, .F => .f,
    .s, .S => .s,
    .c, .C => .c,
    .o, .p => .fn_,
    .m => .dict,
    .M => .table,
    else => .unknown,
  };
}

fn joinElem(a: Elem, b: Elem) Elem {
  if (a == b) return a;
  const ra = numRank(a) orelse return .unknown;
  const rb = numRank(b) orelse return .unknown;
  return fromNumRank(@max(ra, rb));
}
fn numRank(e: Elem) ?u8 {
  return switch (e) { .b => 0, .i => 1, .f => 2, else => null };
}
fn fromNumRank(r: u8) Elem {
  return switch (r) { 0 => .b, 1 => .i, else => .f };
}

fn tyEql(a: Ty, b: Ty) bool {
  if (a.elem != b.elem or a.rank != b.rank) return false;
  for (0..tymod.MAX_RANK) |i| if (!a.shape[i].eql(b.shape[i])) return false;
  return true;
}

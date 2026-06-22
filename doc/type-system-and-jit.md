# Type System & JIT — design report (for future re-implementation)

This is a **design report**, not live code. A type-inference layer, a JIT-stencil
catalog, typed dispatch, elementwise fusion, a native (copy-and-patch) JIT, and
type-stable globals were prototyped end-to-end and then **removed** from the
runtime because nothing depended on them: the inference annotations had no
consumer that produced a measurable win, and the scalar native JIT was not faster
than the existing LLVM-auto-vectorized kernels. This document preserves the design
and the working code so it can be rebuilt deliberately, with a consumer in mind,
when there's a reason to.

The **only** piece kept in the tree is the spirv.k vector⊕scalar broadcast (a
genuine bug fix — see §9), because it makes previously-invalid SPIR-V valid.

## 0. Why it was removed — read this first

- **No dependent code.** Inference wrote `IRInst.ty` / `IRInst.stencil`; the only
  consumer was the typed-dispatch opcode, whose speedup over the generic path is
  negligible in an interpreter (it skips a multiply, not the indirect call).
- **The native JIT wasn't faster.** A 3-op chain over 4M i32: the JIT's single
  *scalar* pass measured roughly on par with the vectorized two-pass kernels —
  sometimes slower. The interpreter kernels are already LLVM-auto-vectorized
  (NEON); a scalar JIT loop trades SIMD throughput for one fewer memory pass.
- **Conclusion:** the type system only pays off with a consumer that the
  interpreter doesn't already have — **NEON-vectorized JIT codegen**, a polyhedral
  loop layer, or the shader compiler. Build the consumer first, then the inference.

## 1. Architecture overview

```
source → Lexer → Parser → AST → Compiler(IR) → [optimizer passes] → bytecode → VM
                                       │
                          ┌────────────┴────────────┐
                          │  (1) inferTypes(IR)      │  annotate IRInst.ty
                          │  (2) selectStencils(IR)  │  annotate IRInst.stencil
                          └────────────┬────────────┘
                                       │ consumed by:
              Apply2T/Apply1T (typed dispatch) · ZipChain (fusion) · native JIT
```

The inference ran in `compiler.runOptimizer`, after the existing fixpoint
(`constantFolding`/`peephole`/`dce`) + `inlineLambdas`, before `livenessLocals`.
Both passes only *wrote* annotation fields; `lower` never read them, so toggling
inference was behavior-preserving (the typed-opcode selection was the one place
bytecode changed).

---

## 2. The abstract domain — `Ty`

The inferred type is element-type × rank × shape, projecting down to the runtime
class `K` via `toK` (null ⇒ keep dynamic dispatch). This is richer than `K` (which
fuses element-type with one rank bit), to leave room for nesting and a polyhedral
shape axis.

```zig
// was: src/runtime/infer/type.zig
const std = @import("std");
const K = @import("../../noun/class.zig").K;
const V = @import("../../noun/value.zig").V;

pub const Elem = enum(u8) {
  bottom, unknown,            // ⊥ (worklist seed) / ⊤ (dynamic)
  b, i, f, s, c,              // mirror scalar K backing kinds
  fn_, dict, table,           // opaque element domains
  fn numRank(e: Elem) ?u8 { return switch (e) { .b => 0, .i => 1, .f => 2, else => null }; }
  fn fromNumRank(r: u8) Elem { return switch (r) { 0 => .b, 1 => .i, else => .f }; }
};

pub const Dim = union(enum) {           // a single dimension's size
  unknown, known: u32, symbolic: u16,   // symbolic = polyhedral size-var (future)
  pub fn eql(a: Dim, b: Dim) bool {
    return switch (a) {
      .unknown => b == .unknown,
      .known => |x| b == .known and b.known == x,
      .symbolic => |x| b == .symbolic and b.symbolic == x,
    };
  }
  pub fn join(a: Dim, b: Dim) Dim { return if (a.eql(b)) a else .unknown; }
};

pub const MAX_RANK: u8 = 4;
pub const RANK_TOP: u8 = 0xff;

pub const Ty = struct {
  elem: Elem = .bottom,
  rank: u8 = 0,               // 0 atom, 1 vector, >=2 nested; RANK_TOP = unknown
  shape: [MAX_RANK]Dim = .{ .unknown, .unknown, .unknown, .unknown },

  pub const BOTTOM: Ty = .{ .elem = .bottom, .rank = 0 };
  pub const TOP: Ty = .{ .elem = .unknown, .rank = RANK_TOP };

  pub fn atom(e: Elem) Ty { return .{ .elem = e, .rank = 0 }; }
  pub fn vector(e: Elem, length: ?u32) Ty {
    var t: Ty = .{ .elem = e, .rank = 1 };
    if (length) |n| t.shape[0] = .{ .known = n };
    return t;
  }
  pub fn isBottom(t: Ty) bool { return t.elem == .bottom; }
  pub fn isTop(t: Ty) bool { return t.elem == .unknown and t.rank == RANK_TOP; }

  /// Project to a concrete runtime class, or null when there is no precise one.
  pub fn toK(t: Ty) ?K {
    const scalar: K = switch (t.elem) {
      .b => .b, .i => .i, .f => .f, .s => .s, .c => .c,
      .dict => return .m, .table => return .M, .fn_ => return .o,
      .bottom, .unknown => return null,
    };
    return switch (t.rank) { 0 => scalar, 1 => containerOf(scalar), else => null };
  }

  /// Seed from a runtime class (+ known array length).
  pub fn fromK(k: K, length: ?u32) Ty {
    return switch (k) {
      .b => atom(.b), .i => atom(.i), .f => atom(.f), .s => atom(.s), .c => atom(.c),
      .B => vector(.b, length), .I => vector(.i, length), .F => vector(.f, length),
      .S => vector(.s, length), .C => vector(.c, length),
      .o, .p => .{ .elem = .fn_ }, .m => .{ .elem = .dict }, .M => .{ .elem = .table },
      .L => .{ .elem = .unknown, .rank = 1 },    // heterogeneous list: rank known, elem ⊤
      .blank, .err, .x => TOP,
    };
  }

  /// Componentwise lattice join (least upper bound).
  pub fn join(a: Ty, b: Ty) Ty {
    if (a.isBottom()) return b;
    if (b.isBottom()) return a;
    const e = joinElem(a.elem, b.elem);
    const r = if (a.rank == b.rank) a.rank else RANK_TOP;
    var t: Ty = .{ .elem = e, .rank = r };
    if (r != RANK_TOP and r != 0)
      for (0..@min(r, MAX_RANK)) |i| { t.shape[i] = a.shape[i].join(b.shape[i]); };
    return t;
  }
};

fn joinElem(a: Elem, b: Elem) Elem {
  if (a == b) return a;
  if (a == .bottom) return b;
  if (b == .bottom) return a;
  if (a.numRank()) |ra| if (b.numRank()) |rb| return Elem.fromNumRank(@max(ra, rb));
  return .unknown;
}
fn containerOf(k: K) K { return @enumFromInt(@intFromEnum(k) | K.VEC_BIT); }
```

The numeric cast chain `b ⊏ i ⊏ f` in `joinElem` makes the join match the runtime's
`Upcast2`/`promote` semantics. Finite height on elem+rank ⇒ the worklist
terminates without widening; only `Dim.symbolic` would need a jump-to-⊤ widening.

---

## 3. Transfer tables — single source of truth

The result-type of each verb already exists as comptime Zig (`resultKind1/2` +
`Upcast2`/`Float2`/`Bool2` strategies in `primitive/verb/helper.zig`). Expose it as
queryable comptime tables built from the **same** `Dyads`/`Monads` metadata that
builds the runtime dispatch tables, so they can never drift. A lock-in test runs
every scalar numeric slot through the real kernel and asserts the table matches.

```zig
// was: src/primitive/verb/transfer.zig  (requires `pub` on parseSig/opOf/Dyads/Monads in verbs.zig)
const std = @import("std");
const K = @import("../../noun/class.zig").K;
const Op1 = @import("../../noun/operator.zig").Op1;
const Op2 = @import("../../noun/operator.zig").Op2;
const verbs = @import("verbs.zig");
const h = @import("helper.zig");

const BLANK: K = .blank;  // "no precise transfer" — inference treats as ⊤

fn dyadStrategy(comptime name: []const u8) ?fn (type, type) type {
  const eq = std.mem.eql;
  if (eq(u8, name, "N+N") or eq(u8, name, "N-N") or eq(u8, name, "N*N") or
      eq(u8, name, "N&N") or eq(u8, name, "N|N")) return h.Upcast2;
  if (eq(u8, name, "N%N")) return h.Float2;
  if (eq(u8, name, "B&B") or eq(u8, name, "B|B")) return h.Bool2;
  if (eq(u8, name, "X=X") or eq(u8, name, "X<X") or eq(u8, name, "X>X")) return h.Bool2;
  if (eq(u8, name, "I⌊I") or eq(u8, name, "I÷I")) return h.Int2;
  return null;  // data-dependent / non-numeric verbs (,  #  &  ?  @  …) → custom
}
fn monadStrategy(comptime name: []const u8) ?fn (type) type {
  const eq = std.mem.eql;
  if (eq(u8, name, "-N") or eq(u8, name, "sqr") or eq(u8, name, "abs")) return h.Upcast1;
  if (eq(u8, name, "~x")) return h.Bool1;
  if (eq(u8, name, "sqrt") or eq(u8, name, "exp") or eq(u8, name, "log") or
      eq(u8, name, "sin") or eq(u8, name, "cos")) return h.Float1;
  if (eq(u8, name, "_n")) return h.Int1;
  return null;
}
fn numericish(k: K) bool { return K.isNumeric(k); }

pub const rty_dyad: [Op2.COUNT][K.COUNT][K.COUNT]K = blk: {
  @setEvalBranchQuota(10_000_000);
  var t: [Op2.COUNT][K.COUNT][K.COUNT]K = undefined;
  for (&t) |*p| for (p) |*row| for (row) |*c| { c.* = BLANK; };
  for (std.meta.declarations(verbs.Dyads)) |decl| {   // source order ⇒ &/| overrides land right
    const Verb = @field(verbs.Dyads, decl.name);
    const op = verbs.opOf(Verb, Op2) orelse continue;
    const strat = dyadStrategy(decl.name) orelse continue;
    for (std.meta.fields(Verb)) |f| {
      const sig = verbs.parseSig(f.name);
      if (sig.len != 2 or !numericish(sig[0]) or !numericish(sig[1])) continue;
      t[op.code()][sig[0].code()][sig[1].code()] = h.resultKind2(sig[0], sig[1], strat);
    }
  }
  break :blk t;
};
// rty_monad is built identically from verbs.Monads + resultKind1.

pub fn dyadResult(op: Op2, xk: K, yk: K) ?K {
  const r = rty_dyad[op.code()][xk.code()][yk.code()];
  return if (r == .blank) null else r;
}
```

---

## 4. The inference pass

A forward dataflow fixpoint over the IR. Each `IRInst.ty` starts at ⊥; recompute
from inputs and join until nothing changes. Const seeds exact `Ty` from
`inst.val.?.tag()` + array length. Locals/globals are typed by joining all writes
to a slot (a side table per scope). Reductions collapse rank; `,`/iota have small
hand-written transfers; everything else degrades to ⊤.

```zig
// was: src/runtime/infer/infer.zig  (key structure; transfer arms abbreviated)
pub fn inferTypes(scope_ir: *ir.IR) void {
  const insts = scope_ir.instructions.items;
  if (insts.len == 0) return;
  var locals = Slots{};   // [256]Ty + [256]assigned; read()→TOP if unassigned
  var globals = Slots{};
  for (insts) |inst| {
    if (inst.op == .AssignLocal and inst.arg1 < 256) locals.assigned[inst.arg1] = true;
    if (inst.op == .AssignGlobal and inst.arg1 < 256) globals.assigned[inst.arg1] = true;
  }
  var pass: usize = 0; var changed = true;
  while (changed and pass < insts.len + 4) : (pass += 1) {
    changed = false;
    for (insts) |*inst| {
      if (inst.is_dead) continue;
      const computed = switch (inst.op) {
        .Local, .LocalLast => locals.read(inst.arg1),
        .AssignLocal => blk: { const t = inputTy(scope_ir, inst.*, 0); locals.write(inst.arg1, t); break :blk t; },
        .Global => globals.read(inst.arg1),
        .AssignGlobal => blk: { const t = inputTy(scope_ir, inst.*, 0); globals.write(inst.arg1, t); break :blk t; },
        else => transfer(scope_ir, inst.*),
      };
      const next = inst.ty.join(computed);
      if (!tyEql(next, inst.ty)) { inst.ty = next; changed = true; }
    }
  }
}
// transfer(): .Const → fromValue; .Apply1/.Apply2 → rty_monad/rty_dyad lookup on operands' toK,
// rank/shape from operands; reductions (+/ */ |/ &/) collapse rank; .Nop (cond merge) → join inputs;
// `,` → concat; everything else → Ty.TOP.
```

### Soundness boundary
- **Local typing is sound**: ink lambdas don't capture scope, so a local slot's
  only writers are this scope's `AssignLocal`s, and the join covers them all.
- **Global typing is speculative**: a callee can reassign a global via `::` between
  the analysis's write and read. It was only safe because the sole consumer
  (typed dispatch, §6) guards operand tags at runtime. Any *unguarded* consumer
  (polyhedral codegen) must restrict itself to local/const provenance, or rely on
  **type-stable globals** (§8).

---

## 5. Stencil catalog (the JIT/codegen hand-off)

A *stencil* is a monomorphic verb instance — `(+, I, I) → I`. The catalog is the
non-`blank` domain of the transfer tables, so the JIT's stencil set, inference, and
the runtime kernels all trace to one comptime definition.

```zig
// was: src/jit/stencil.zig
pub const DyadStencil = struct { op: Op2, x: K, y: K, out: K };
pub const NONE: u16 = 0xffff;
pub const dyad_stencils: []const DyadStencil = blk: {   // built from rty_dyad non-blank slots
  var list: []const DyadStencil = &.{};
  for (allK()) |xk| for (allK()) |yk| for (std.meta.fields(Op2)) |opf| {
    const op: Op2 = @enumFromInt(opf.value);
    const out = xfer.rty_dyad[op.code()][xk.code()][yk.code()];
    if (out != .blank) list = list ++ .{DyadStencil{ .op = op, .x = xk, .y = yk, .out = out }};
  };
  break :blk list;
};
pub fn selectDyad(op: Op2, xk: K, yk: K) ?u16 { /* reverse-lookup id table */ }
```

`infer.selectStencils(*IR)` then tags each `Apply2`/`Apply1` whose operands give
concrete `toK` with the serving stencil id, into `IRInst.stencil`.

---

## 6. Typed dispatch — `Apply2T` / `Apply1T`

The interpreter consumer. `lowerInst` emits a typed opcode (carrying the expected
operand class codes inline) when a stencil was selected; `instSize`/`Chunk.instrSize`
account for the extra bytes; `disasm.zig` prints them. At runtime the VM **guards**
the actual tags and falls back to generic dispatch on any mismatch — which makes
the fast path sound regardless of inference accuracy (an `err` value, or a
speculative global being wrong, just takes the dynamic path).

```zig
// was: in vm.zig run-loop:  .Apply2T => try vm.doApplyTyped(2),
fn doApplyTyped(vm: *VM, comptime arity: usize) !void {
  const op = vm.readByte();
  const xkc = vm.readByte();
  const ykc = if (arity == 2) vm.readByte() else 0;
  const s = vm.size(); const a = vm.cut(arity);
  const r = blk: {
    if (arity == 2) {
      if (a[0].tag().code() == xkc and a[1].tag().code() == ykc) {
        const key = @as(usize, op) * K.COUNT * K.COUNT + @as(usize, xkc) * K.COUNT + ykc;
        break :blk dispatch.dispatch2At(vm, key, a[0], a[1]);   // call kernel by precomputed key
      }
      break :blk dispatch.dispatch2(vm, @enumFromInt(op), a[0], a[1]); // fall back
    } else { /* monadic mirror */ break :blk dispatch.dispatch1(vm, @enumFromInt(op), a[0]); }
  };
  for (a) |*v| v.deinit(vm.alloc);
  vm.stack_len = s - arity;
  try vm.push(r);
}
```

**Honest note:** in a bytecode interpreter this saves only the dispatch-key
arithmetic, not the indirect call — the win is marginal. `Apply2T` is really the
*hook* a native backend replaces with a stencil call.

---

## 7. Elementwise chain fusion — `ZipChain`

A structural peephole (does *not* need inference) that fuses `(x∘y)∘z` arithmetic
chains with a single-use intermediate into one pass via a comptime-specialized
runtime-type-guarded kernel, mirroring the existing `ReduceZip`. Suppressed when
the result feeds a fusable reducer (ReduceZip's scalar result wins).

```zig
// was: in primitive/derived/fuse.zig — the kernel
pub fn zipChain(vm: *VM, out: Op2, in: Op2, side: u8, s0: V, s1: V, s2: V) V {
  const t = s0.tag();
  if (t == s1.tag() and t == s2.tag() and (t == .I or t == .F) and
      s0.len() == s1.len() and s1.len() == s2.len() and s0.len() > 0)
    if (chainFast(vm, t, out, in, side, s0, s1, s2)) |r| return r;
  // fallback = exact two-step semantics
  if (side == 0) { const tmp = dispatch.dispatch2(vm, in, s0, s1); defer tmp.deinit(vm.alloc);
                   return dispatch.dispatch2(vm, out, tmp, s2); }
  else           { const tmp = dispatch.dispatch2(vm, in, s1, s2); defer tmp.deinit(vm.alloc);
                   return dispatch.dispatch2(vm, out, s0, tmp); }
}
```

**Gotcha that cost a debugging session:** operands reach the VM stack in
**IR-emission order**, not `inst.inputs[]` order. For a right-nested chain
(`a+b*c` = `a+(b*c)`) the "other" operand is emitted first, so the fused input list
is `[other,x,y]` and the kernel must group `(s1,s2)` — getting this wrong made
`a+b*c` compute `(a*b)+c`. Regression-test both nesting sides.

---

## 8. Type-stable globals (language-level)

Makes global typing more trustworthy by enforcing, at runtime, that a *committed*
(non-empty) global keeps its **type family** (numeric{b,i,f,B,I,F} / symbol / char
/ list / dict / …). Cross-family reassignment of a committed global → a `type`
error, old value kept. **Empty containers and unset slots are exempt** — this was
essential: strict same-class enforcement broke the font library's idiomatic
"init a registry as `()`, then populate it as a dict" pattern.

```zig
// was: vm.zig — VM gets `global_class: [256]K`; AssignGlobal checks:
fn classFamily(k: K) u8 {
  if (k.isNumeric()) return 1;
  return switch (k) { .s, .S => 2, .c, .C => 3, .L => 4, .m => 5, .M => 6, .o, .p => 7, .x => 8, else => 9 };
}
fn typeStableViolation(old: K, new: K, old_empty: bool, new_empty: bool) bool {
  if (old == .blank or new == .blank) return false;     // unset / clearing
  if (old_empty or new_empty) return false;             // empty container ≠ committed
  return classFamily(old) != classFamily(new);
}
// in AssignGlobal: if (typeStableViolation(global_class[i], val.tag(), globals[i].len()==0, val.len()==0))
//                    { val.deinit; push .{err=.type}; } else { store; global_class[i]=val.tag(); }
```

Numeric stays fluid (`a:1` → `a:2 3` → `a:1.5`); `a:1 2 3` then `a:\`sym` is an
error. This was removed with the rest; reintroduce it only if a consumer needs
sound (not just guarded) global types.

---

## 9. Native JIT (copy-and-patch) — proven, not wired

A full vertical was built and tested in isolation on Apple Silicon: W^X executable
memory, an AArch64 emitter, single-op stencils, and an arbitrary-length fused-chain
compiler. Every test JIT-compiled **and ran** the generated machine code against a
Zig oracle, so an encoding error was a contained test failure, never a silent
miscompile.

```zig
// was: src/jit/exec.zig — W^X executable memory (aarch64 macOS)
pub const supported = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) *anyopaque;
extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
const MAP_JIT: c_int = 0x0800;  // + MAP_PRIVATE(0x2) | MAP_ANON(0x1000), PROT_READ|WRITE|EXEC
pub const ExecBuf = struct {
  ptr: [*]u8, len: usize,
  pub fn install(self: ExecBuf, code: []const u8) void {
    pthread_jit_write_protect_np(0);            // writable
    @memcpy(self.ptr[0..code.len], code);
    pthread_jit_write_protect_np(1);            // executable
    sys_icache_invalidate(self.ptr, code.len);  // flush icache
  }
  pub fn entry(self: ExecBuf, comptime Fn: type) Fn { return @ptrCast(@alignCast(self.ptr)); }
};
```

```zig
// was: src/jit/emit.zig — minimal AArch64 emitter (encodings from register fields)
fn ldrWreg(rt: Reg, rn: Reg, rm: Reg) u32 { return 0xB8607800 | (@as(u32,rm)<<16) | (@as(u32,rn)<<5) | rt; } // ldr Wt,[Xn,Xm,lsl#2]
fn strWreg(rt: Reg, rn: Reg, rm: Reg) u32 { return 0xB8207800 | (@as(u32,rm)<<16) | (@as(u32,rn)<<5) | rt; }
pub fn addWreg(rd: Reg, rn: Reg, rm: Reg) u32 { return 0x0B000000 | (@as(u32,rm)<<16) | (@as(u32,rn)<<5) | rd; }
pub fn mulWreg(rd: Reg, rn: Reg, rm: Reg) u32 { return 0x1B007C00 | (@as(u32,rm)<<16) | (@as(u32,rn)<<5) | rd; }
fn movzX(rd: Reg, imm16: u16) u32 { return 0xD2800000 | (@as(u32,imm16)<<5) | rd; }
fn addImmX(rd: Reg, rn: Reg, imm12: u12) u32 { return 0x91000000 | (@as(u32,imm12)<<10) | (@as(u32,rn)<<5) | rd; }
fn subsX(rd: Reg, rn: Reg, rm: Reg) u32 { return 0xEB000000 | (@as(u32,rm)<<16) | (@as(u32,rn)<<5) | rd; }   // cmp = subs xzr
fn ldrXimm(rt: Reg, rn: Reg, imm12: u12) u32 { return 0xF9400000 | (@as(u32,imm12)<<10) | (@as(u32,rn)<<5) | rt; }
fn cbzX(rt: Reg, off: i32) u32 { return 0xB4000000 | ((@as(u32,@bitCast(off)) & 0x7FFFF)<<5) | rt; }
fn bcond(cond: u32, off: i32) u32 { return 0x54000000 | ((@as(u32,@bitCast(off)) & 0x7FFFF)<<5) | cond; }   // LO=0b0011
const RET: u32 = 0xD65F03C0;

// arrayBinOp loop: out[i]=x[i] OP y[i]   (x0=out x1=x x2=y x3=n x4=i w5,w6=tmp)
//   cbz x3,end; movz x4,#0; loop: ldr w5,[x1,x4,lsl#2]; ldr w6,[x2,x4,lsl#2]; OP w5,w5,w6;
//   str w5,[x0,x4,lsl#2]; add x4,x4,#1; cmp x4,x3; b.lo loop; end: ret   (patch forward/back branches)
//
// arrayChain(tape): compile an arbitrary postfix tape (load k / binop) over a set of
// leaf arrays into ONE native loop using a register value-stack (w8..w15, depth ≤ 8).
// ABI: void(i32* out, const i32* const* leaves, usize n).  This is the unique capability
// runtime codegen adds over the static kernels: a runtime-shaped expression → native code.
```

**Measurement & verdict.** The arbitrary-length chain compiler worked (5 chain
shapes verified vs a Zig oracle). But a benchmark of `((a+b)*c)-d` over 4M i32 put
the JIT's single scalar pass at parity with — sometimes slower than — the
vectorized multi-pass kernels. **A real win needs NEON-vectorized codegen.** Until
then the JIT is a proven capability with no profitable place to plug in.

---

## 10. spirv.k (kept: vector⊕scalar broadcast bug fix)

The shader compiler had ad-hoc typing that **silently emitted invalid SPIR-V** for
`v2 + f32`: `OpFAdd` requires both operands to share a type. The fix (the one piece
kept in the tree, `lib/spirv.k`) splats the scalar to the vector first:

```k
splat: {[vty; sid]
  n: ncVec[vty]; rt: Tid[vty]; r: newId[]
  $[n=2; emitBuf opCons2[rt;r;sid;sid]
    n=3; emitBuf opCons3[rt;r;sid;sid;sid]
    emitBuf opCons4[rt;r;sid;sid;sid;sid]]
  r}
// in compTransNorm, for +,-,% on vector⊕scalar:
//   bcast: (op in `+`-`%) & isVecTy[rty] & ~(isVecTy[aty] & isVecTy[bty])
//   aId/bId: splat the scalar operand to rty;  da/db: rty.
```

`spirv-val` confirms `{[uv] uv+0.5}` now compiles to valid SPIR-V (the
disassembly shows `OpCompositeConstruct %v2float %f %f` then `OpFAdd %v2float`).

**Not kept (a type-soundness feature, was prototyped):** a sound `binResolve` that
also detects **width mismatches** (`v2 + v4`) and records a `SpvErr` diagnostic
instead of emitting garbage. If revisited, give spirv.k a real `(element ×
vector-width)` lattice with a sound `join` (mismatch → error), and validate output
with `spirv-val` in `test/spirv.k`. Also still open: compute-shader I/O is
hardcoded `f32` in `compCompute`.

---

## 11. Recommended path, if rebuilt

1. **Pick the consumer first.** The type system is dead weight without one whose
   win the interpreter can't already get: (a) NEON-vectorized JIT chain codegen,
   (b) a polyhedral loop layer using `Dim.symbolic`, or (c) the shader compiler.
2. **Re-add inference + transfer tables (§2–4)** — they're cheap, behavior-preserving,
   and the lock-in test keeps them honest.
3. **Build the consumer**, measure against the existing vectorized kernels, and only
   then wire typed dispatch / fusion / native stencils where the numbers justify it.
4. **Type-stable globals (§8)** is the prerequisite for *unguarded* consumers to
   trust global types.
```

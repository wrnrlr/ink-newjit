# JIT / Optimizer Implementation Feedback

## What was completed (Tasks 1–11)

1. Optimizer fixed-point convergence loop (removed arbitrary 10-iteration cap)
2. Constant folding extended to floats and booleans
3. Apply1 stencil (monadic ops stay in Phase 1)
4. Chunk.blocks — BB graph retained after livenessLocals for the JIT emitter
5. Const and AssignLocal stencils
6. Lambda inlining for single-op bodies (arity ≤ 2, pure)
7. Branch stencils (JumpFalse / JumpTrue with dual NEXT holes) + forward-jump backpatching
8. Type-specialised Apply2 stencils for the 6 hot arithmetic ops (add/sub/mul/lt/gt/eq on int×int)
9. Frame-free Phase 2 (STP X19,X30 / LDP X19,X30 instead of full frame record; saves 3 instructions per lambda entering Phase 2)
10. liftInvariants wired into the pipeline (stub with design notes)

---

## What could not be implemented

### Task 10 — Loop-invariant code motion (LICM)

True LICM requires eliminating redundant Global reads across uses without re-fetching from the global table.  The obstacle is the stack machine model:

- In a register machine (or SSA), replacing instruction `j` with the result of an earlier instruction `i` is safe as long as `i` dominates `j` and the value hasn't changed.
- In a stack machine, values are consumed (popped) as they are used.  Once `Global X` is consumed by `Apply2`, its stack slot is gone.  Reusing it at a later site without re-pushing causes a stack underflow.

The two correct approaches, neither of which was implemented:

**Option A — DUP instruction**: emit `Global X; DUP; Apply2; …; (use cached value)`.  Ink's bytecode has no DUP.  Adding it would require new opcode, VM handler, and JIT stencil.

**Option B — temp-local round-trip**: emit `Global X; AssignLocal T; Local T` at the first read site, and `Local T` at subsequent sites.  This is semantically correct and compatible with ref-counting.  It requires the lowering pass (`lowerInst`) to be aware of "this Global has been cached in slot T" metadata, stored in the IRInst (e.g., a `cache_slot: ?u8` field).  The optimizer would fill this field; the lowerer would use it.  The change is ~40 lines but touches three files (ir.zig, optimizer.zig, compiler.zig) and needs careful handling of the new local slot in the lambda's locals count.

The call site in the compiler pipeline is in place — `liftInvariants` is called before `livenessLocals`.  Only the implementation body needs to be filled in when the DUP or temp-local approach is adopted.

---

## What can still be improved

### Global stencil

`Global X` always falls to Phase 2.  A stencil could inline the load:

```
LDR X2, [X0, #globals_offset]   ; vm.globals ptr
LDR X1, [X2, X1, LSL #3]        ; globals[idx]
<ref-count increment>
<stack push>
NEXT hole
```

The ref-count increment is the tricky part (it's a conditional atomic on heap types).  For scalar globals (`.i`, `.f`, `.b`) it is a no-op, so a fast-path-only stencil with a type-tag guard and fallback to the handler would cover the common case.

### Float type-specialised stencils

The six specialised Apply2 stencils cover `int × int`.  Adding `add_ff`, `sub_ff`, `mul_ff`, `lt_ff`, `gt_ff`, `eq_ff` for `float × float` follows the exact same pattern and would cover numeric finance code that uses floats.

### CPS handler chain (fully frame-free Phase 2)

The current Phase 2 saves `X19` + `X30` and restores them around BL calls to handler functions.  A fully CPS design eliminates even this:

- Change handler signatures to `fn(vm: *VM, next: *const fn(*VM) callconv(.c) void) callconv(.c) void`.
- Each handler does its work, then tail-calls `next` (the next handler's address, passed as an argument).
- The emitter passes the chain of `next` pointers at JIT time.
- No STP/LDP needed at all; the frame disappears entirely.

This is a larger refactor (all ~15 handler signatures change) but the payoff is that Phase 1 and Phase 2 become a uniform continuation chain — no architectural boundary between stencil ops and handler ops.

### Stencil composition / generators

The Copy-and-Patch paper describes *generators* that fuse multiple adjacent ops into a single stencil blob, removing the per-stencil `BR X8` chain.  For a tight two-arg lambda like `{x+y}`, the stencils are:

```
[stencilLocal 0] → BR X8 → [stencilLocal 1] → BR X8 → [stencilAdd_ii] → BR X8
```

A composed stencil for "load-local-0; load-local-1; add-int-int" would be a single blob with one NEXT hole.  Profile first — if the per-stencil `BR X8` overhead is already below measurement noise, composition is not worth the complexity.

### Profile-guided stencil selection

The type-specialised stencils (`add_ii`, etc.) are selected statically based on the opcode byte.  With a lightweight call counter per lambda, the emitter could:

- On first call: use handler path, record observed types.
- On second call (hot): re-JIT with the type-matched specialised stencil.
- On type mismatch at runtime: fall back to the general handler.

This is standard inline-cache / polymorphic-inline-cache territory.  The JIT cache already stores one entry per lambda; extending it to store a "type seen" byte alongside would be minimal overhead.

### LICM with temp-local caching (follow-up to Task 10)

As described above, the correct implementation is:

1. Add `cache_slot: ?u8 = null` to `IRInst`.
2. In `liftInvariants`, scan for Globals that appear more than once with no intervening `AssignGlobal`.  For each, allocate a new local slot (`lambda.locals++`) and set `cache_slot` on the first occurrence.  Mark subsequent occurrences dead and patch their consumers' inputs to the first occurrence's id.
3. In `lowerInst`, when emitting a `Global` instruction with `cache_slot != null`, emit: `Global X; AssignLocal T; Local T` (three bytecode instructions instead of one).  When emitting a dead `Global` whose id was replaced, emit nothing (already handled by `is_dead` check).

The net effect: each unique invariant Global is loaded once per lambda call, stored in a fast local slot, and read from there on subsequent uses.  Local reads are handled by stencils (Phase 1, no frame overhead); Global reads fall to Phase 2.  For a lambda like `{(x+y)*scale - scale}` called N times by fold, this eliminates one Phase 2 handler call per iteration.

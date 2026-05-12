# Future Changes and Improvements

## JIT (Copy-and-Patch)

### Near-term: more stencil ops

**`Apply1` stencil**
Mirrors `stencilApply2` exactly. Add a `vm.jit_apply1` function-pointer field to the VM struct (pointing to an `apply1Worker` helper) and a `stencilApply1` function. The emitter picks it up in Phase 1 for any monadic op, keeping the apply entirely out of the handler section. ~20 lines, no architecture changes.

**`Const` stencil**
Push a compile-time constant from the chunk's constant pool. The operand hole carries the u8 index; the stencil loads `vm.current_chunk`, dereferences `constants.items[idx]`, calls the inline `stencilRef` helper, and pushes. Fits the existing single-OPERAND-hole design. The trickiest part is keeping the stencil body free of ADRP (no jump tables), which the `inline` arms of `stencilRef` already ensure.

**`AssignLocal` stencil**
A fast-path-only variant: if the slot holds a non-heap type (`.i`, `.f`, `.b`, `.blank`) skip the deinit and store directly. On any heap type fall back to the handler. This covers the common case of assigning integer/boolean results inside tight lambdas without entering the handler section.

### Medium-term: branch stencils (loops stay in Phase 1)

Currently `JumpFalse` / `JumpTrue` immediately break out of Phase 1, so any lambda with a branch — including every loop — runs in the handler section. The fix:

Add a **second patchable NEXT hole** to the branch stencils. A `JumpFalse` stencil pops the condition, checks it, and has two MOVZ/MOVK/BR sequences: one for the fall-through path and one for the taken path. `StencilInfo` gains a `branch_offset: ?usize` field; `patchBranch()` mirrors `patchNext()`. The emitter tracks two pending holes instead of one.

This is the largest single performance win for array code with inner loops.

### Medium-term: type-specialised Apply2 stencils

`stencilApply2` always goes through `apply2Worker` → `dispatch2`, even for `+` on two integers. Specialised stencils — e.g. `stencilAdd_ii` — would inline the fast path (`x.i +% y.i`) with a type-tag guard that falls back to the handler only when the types don't match. This eliminates dispatch overhead for the hottest path in numeric array code.

### Longer-term: stencil composition (generators)

The Copy & Patch paper describes *generators* that fuse multiple ops into a single combined stencil — e.g. "load two locals and apply a dyadic op" emitted as one blob. This removes the chain of `BR X8` jumps between individual stencils in tight lambda bodies like `{x+y}`. Worth revisiting once branch stencils are in place and profiling shows the per-stencil overhead is significant.

---

## CPS-style execution

The paper describes Copy-and-Patch as "CPS-inspired": each stencil is a continuation that does its work and jumps directly to the *next* continuation via `BR X8` — no central dispatch loop, no return. Phase 1 already is this. Phase 2 is not.

### Basic block decomposition (prerequisite for CPS branches)

The emitter currently treats each lambda as a flat sequence and falls back to Phase 2 at the first branch. The CPS fix is to pre-scan the bytecode into **basic blocks** — maximal linear sequences with no internal branches — and compile each block as its own JIT function. A `JumpFalse` in block 0 becomes a branch stencil with two NEXT holes patched to the compiled addresses of block 1 and block 2. Loops then stay entirely in Phase 1 across iterations: the loop body is a stencil chain that ends with a branch stencil calling back into itself.

This requires:
- A pre-pass in the emitter that identifies block boundaries and jump targets before emitting any code
- The JIT cache storing a table of (block_start_ip → JitFn) per lambda instead of a single entry
- The branch stencil from the section above

### Frame-free Phase 2 (CPS handler chain)

The Phase 2 handler section needs a `STP/LDP` frame because handlers are called with `BL` and return normally. In a fully CPS design, each handler would not return — it would tail-call the next handler in the chain. This eliminates the frame entirely and lets Phase 1 and Phase 2 merge into a single uniform continuation chain.

Concretely: change handler stubs from `fn(vm, operand) void` to `fn(vm, operand, next: *const fn(*VM) void) void`. The emitter passes each handler the address of the next one as an argument. The last handler in the chain receives a sentinel "return to caller" continuation. The `STP x19,x20` / `LDP x19,x20` and the outer `RET` disappear.

This is a larger refactor (all ~15 handler signatures change) but the result is a single execution model — stencil and handler continuations are indistinguishable at runtime.

---

## Compiler: expose basic block data

The optimizer already computes the full basic block graph — leaders, successor edges, gen/kill sets, liveness — inside `livenessLocals` (`optimizer.zig:179–304`). It throws this away after marking `LocalLast`. The emitter needs this same information to implement per-block JIT compilation.

**Task:** after `livenessLocals` runs, retain the BB table in a new `Chunk.blocks` field (array of `{start_ip, end_ip, succ[2]}`). The JIT emitter reads this instead of re-deriving it from the bytecode. No new analysis is needed — it's already there, just not surfaced.

As a smaller alternative, the emitter could re-derive BBs itself in ~30 lines (the bytecode format is simple enough). Either approach unblocks branch stencils and per-block JIT compilation.

---

## Optimizer improvements

### Fix constant folding coverage

`foldMonad` and `foldDyad` in `optimizer.zig` both begin with `if (x == .i)` and return `null` for everything else. Float, boolean, and simple vector constants are never folded. Extend both functions to cover `.f` (float arithmetic, comparisons) and `.b` (boolean logic). This is purely additive — no structural change.

### Fix the convergence loop

The `optimize` loop runs up to 10 fixed iterations (`while (changed and iter < 10)`). The comment in the source flags this as suspicious. Replace with a true fixed-point loop: `while (try self.constantFolding(...) or try self.dce(...)) {}`. Ten iterations is almost always enough in practice, but the bound is arbitrary and hides the intent.

### Implement loop-invariant code motion

`liftInvariants` exists as a stub (`optimizer.zig:171`) that always returns `false`. For array code, expressions like `#x` (count), `*x` (first), or any pure function of a variable that doesn't change across loop iterations can be hoisted out of the loop body. The BB graph built for liveness is the right foundation: an expression is invariant if all its inputs are defined outside the loop's back-edge.

### Lambda inlining for simple bodies

A lambda like `{x+y}` called as the body of `+/` (fold) or `'{f}` (each) could be inlined at the call site in the IR, replacing `Call` + frame overhead with a direct `Apply2`. The guard is: lambda is pure (`is_pure`), has arity ≤ 2, and its body compiles to a single `Apply1`/`Apply2`. The IR already tracks `is_pure`; the inliner just substitutes the lambda's IR nodes at the call site before lowering.

---

## Verbs: selective type-specialised stencils

The `dispatch.zig` scalar fast paths (`x.i +% y.i`, etc.) are the right model for type-specialised stencils. For a stencil to be safe to copy it must be position-independent — no ADRP, no access to `monad_table`/`dyad_table`. The ~8 core arithmetic ops (`+`, `-`, `*`, `%`, `&`, `|`, `<`, `>`, `=` on `.i` and `.f`) satisfy this: their implementations in `calc.zig` are a single arithmetic expression with no global data access.

**Task:** add one stencil per hot (op, type-pair) combination, e.g. `stencilAdd_ii`, `stencilSub_ii`, `stencilMul_ff`. Each stencil:
1. Reads the opcode from the OPERAND hole (same as `stencilApply2`)
2. Loads the top two stack values
3. Checks their tags — if they don't match, falls through to `apply2Worker`
4. Performs the inline arithmetic and pushes the result
5. Jumps via the NEXT hole

The emitter selects the specialised stencil when it can prove (statically or via profile feedback) that the types will match. Initially, emit the specialised stencil unconditionally and let the guard handle mismatches — wrong-type calls degrade to the handler path, not incorrect behaviour.

Do **not** extend this to all 60 verbs. Complex ops (sort, search, string manipulation) involve allocation and control flow that cannot be expressed as position-independent stencils. The fast-path scalar arithmetic in `dispatch.zig` is the precise set worth specialising; everything else stays in the handler path.

The `dispatch.zig` fast paths themselves should be kept: they serve the interpreter and the Phase 2 handler path for cases the stencils don't cover.

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

The C&P paper describes *generators* that fuse multiple ops into a single combined stencil — e.g. "load two locals and apply a dyadic op" emitted as one blob. This removes the chain of `BR X8` jumps between individual stencils in tight lambda bodies like `{x+y}`. Worth revisiting once branch stencils are in place and profiling shows the per-stencil overhead is significant.

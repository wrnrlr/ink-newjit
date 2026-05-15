# JIT / Optimizer Implementation Feedback

## What was completed (Tasks 1–11) after Run 1

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

## What was completed (Tasks 12–15) after Run 2

12. Float type-specialised stencils — extended `specDyadInt` → `specDyad`, adding a float×float fast-path branch alongside the existing int×int branch.  All six arithmetic ops (add/sub/mul/lt/gt/eq) now cover both type pairs in a single stencil function; no separate `_ff` functions needed, no emitter changes.

13. DUP opcode — new `Dup` entry in `OpCode`, interpreter handler (`opDup`), JIT handler stub (`jhDup`), and pure-leaf stencil (`stencilDup`, uses `stencilRef` for correct refcounting).  Wired into Phase 1 (stencil) and Phase 2 (handler call).  The optimizer does not yet emit DUP; it is infrastructure for future CSE passes.

14. Global stencil — `stencilGlobal` with scalar fast-path: `.i`, `.f`, `.b`, `.blank` are pushed inline without a refcount increment.  Heap types call `globalWorker` via the new `vm.jit_global` function pointer (same pattern as `jit_apply2`).  Registered with `scanWithFrame orelse scan2WithFrame` for ReleaseFast compatibility.

15. LICM via temp-local — fully implemented `liftInvariants`: added `cache_slot: ?u8` to `IRInst` and `extra_locals: u8` to `IR`.  The pass scans each lambda for duplicate `Global` reads of the same index with no intervening write, allocates a fresh local slot, and converts subsequent reads to `Local` instructions.  `lowerInst` expands a cached Global to `Global X; AssignLocal T; Local T`.  `compileLambda` now adds `extra_locals` to the lambda frame's `locals` count.

---

## Bugs unexpectedly found

### liftInvariants running on top-level code (two test failures)

**Symptom**: Two tests failed after LICM was implemented: `test.list assign` produced `(;3)` instead of `4 6`, and `test.do not reuse the left argument` produced an empty string instead of `1 2 3`.

**Root cause**: The previous session had wired `liftInvariants` into both `compile()` (top-level code path) and `compileLambda()`.  While the pass was a stub (always returned false) this was harmless.  Once implemented, the top-level call became dangerous: top-level code runs in the initial frame with `base = 0` and no reserved local slots — the VM never calls `callLambda` for top-level code, so no blank slots are pushed.  When LICM assigned cache slot 0 and the lowering emitted `AssignLocal 0`, it wrote to `stack[0]`, which is also the bottom of the evaluation stack → silent corruption.

**Fix**: Removed the `liftInvariants` call from `compile()`.  The pass now only runs inside `compileLambda()`, where the frame layout is guaranteed by `callLambda`'s blank-pushing.

### ListAssignGlobal not treated as a write barrier

**Symptom**: Latent — would have produced stale global reads for expressions like `(a;b)*:2; a` where a list assignment modifies a previously cached global.

**Root cause**: The LICM scan only broke on `AssignGlobal` when looking for writes that invalidate a cached global.  `ListAssignGlobal` (emitted for patterns like `(a;b)*:2`) can write any global in the list but was invisible to the scan.  Similarly, `Amend` and `Dmend` can modify global state through references.

**Fix**: Added `ListAssignGlobal`, `Amend`, and `Dmend` as unconditional break conditions in both the duplicate-detection scan and the conversion loop inside `liftInvariants`.

---

## What was completed (Tasks 16–17)

16. **`jit_ref` helper** — Added `jit_ref: *const fn(*VM) callconv(.c) void` to the VM struct, implemented by `refWorker` which refcounts `vm.stack[vm.stack_len - 1]` in-place via the standard `V.ref()` call.  `stencilLocal`, `stencilConst`, and `stencilDup` now call `vm.jit_ref(vm)` via LDR+BLR instead of inlining the multi-arm `stencilRef` switch.  All three stencils are registered with `scanWithFrame` (which preserves the STP/LDP frame around the BLR).  In ReleaseFast they now produce a single linear NEXT hole — no escaping branches — so they stay in Phase 1 instead of falling back to Phase 2.  `stencilRef` was removed.

17. **ReleaseFast SIGILL fix (scan3WithFrame)** — `specDyad` has three code paths (int fast, float fast, slow BLR).  In ReleaseFast, LLVM tail-duplicates the NEXT hole into all three arms, producing three sentinel sequences.  `scan2WithFrame` only captured two, leaving the third unpatched → SIGILL.  Added `branch_offset2: ?usize` to `StencilInfo` and a new `scan3WithFrame` scanner.  The emitter registers all three holes as pending branches targeting the same successor.  Fallback chain for all six arithmetic stencils is now `scanWithFrame orelse scan2WithFrame orelse scan3WithFrame`.  `stencilGlobal` was simultaneously simplified to a single BLR callsite (using `and blk:` short-circuit) to keep it at ≤2 NEXT holes.


### ~~stencilGlobal: heap globals still Phase 2~~ — **fixed**

`stencilGlobal` was rewritten to push `globals[idx]` (or `.blank` for out-of-range) unconditionally, then always call `vm.jit_ref(vm)` to bump the refcount.  For scalars `jit_ref` is a no-op; for heap types it increments the refcount.  `globalWorker` is no longer called from the stencil.  All globals now stay in Phase 1.

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

## What was completed (Tasks 21–22) after Run 4

21. **MakeList, Derive, MakeDict in Phase 2** — Added `make_list`, `derive`, `make_dict` to the `Handlers` struct in `emit.zig`. Added `jhMakeList`, `jhDerive`, `jhMakeDict` handler functions (thin wrappers around the existing worker functions). Added Phase 2 switch cases for `.MakeList`, `.Derive`, `.MakeDict`. These ops are already in Phase 1 for most lambdas, but this ensures they are also handled when Phase 2 is entered (e.g., a lambda with a `Call` before a `MakeList`).

22. **SIMD array comparison stencils** (`lt_II`, `gt_II`, `eq_II`, `lt_FF`, `gt_FF`, `eq_FF`) — Extended `simdBinopII` and `simdBinopFF` to handle `<`, `>`, `=` operators using `@Vector(4, T)` SIMD loops, producing `N(bool)` output. Added 6 new stencil functions that route through `vm.jit_simd_array2`. Added entries to `StencilTable` and selection in `emit.zig` for `type_hint == 3` (I×I) and `type_hint == 4` (F×F). Profile-guided re-JIT now covers all 6 arithmetic+comparison ops for both int and float arrays. Filtering patterns like `v[v > threshold]` now use SIMD comparisons after the second call.

23. **Phase 2 support for Call, TailCall, Apply, MakePartial** — Added `call`, `tail_call`, `apply`, `make_partial` to the `Handlers` struct. Added `jhCall`, `jhApply` (use a stack buffer for up to 8 args, call `vm.executeCall` which runs the callee to completion before returning), `jhTailCall` (resets the current frame's lambda/chunk/ip for the tail target — the JIT epilogue returns and the interpreter picks up from the new frame), and `jhMakePartial` (replicates `doMakePartial` logic without `readByte()`; packs argc+mask into a single u16 operand). `TailCall` in Phase 2 breaks immediately after emitting its handler call, like `Jump`. With these additions, the JIT now handles all 23 opcodes via Phase 1 stencils or Phase 2 handlers. The only ops that force interpreter fallback are `Amend`, `Dmend`, `ListAssignGlobal`, `ListAssignLocal`, `MakeTable`, and `Command`.

---

## What was completed (Tasks 18–20) after Run 3

18. **CPS design doc** — Written to `doc/cps.md`. Explains why full CPS (changing handler signatures to pass `next` continuation pointer) is deferred: the Return terminal stencil already eliminates Phase 2 for the most common case (simple lambdas ending at Return), and CPS adds code density overhead for N≥2 Phase 2 ops (5 instructions per thunk vs 4-instruction fixed frame amortised). The doc includes a density comparison table, thunk encoding cost analysis, and a list of conditions under which CPS would become worth implementing.

19. **Terminal stencil for Return** — Added `is_terminal: bool = false` to `StencilInfo`. `scanTerminal` scans for the first RET instruction (0xD65F03C0) and returns a `StencilInfo` with `is_terminal = true`. The emitter detects terminal stencils and returns immediately from Phase 1 without entering Phase 2. Lambdas ending at Return (e.g., `{x+y}`, `{x*scale}`) now run entirely in Phase 1 — no `STP X19,X30 / LDP X19,X30` frame at all.

20. **Stencils for remaining opcodes** — Four new stencil registrations and Phase 1 coverage for previously Phase-2-only ops:
    - **Nop**: handled inline in the emitter — `ip += 1; continue`, zero cost, no stencil.
    - **Drop**: `dropWorker` calls `vm.pop().deinit`; `stencilDrop` uses `scanWithFrame`.
    - **AssignGlobal**: `assignGlobalWorker` pops, writes to `vm.globals[idx]`, pushes blank; stencil has OPERAND hole for index.
    - **MakeList**: `makeListWorker(vm, n)` pops N items and calls `V.Values`; OPERAND hole for N.
    - **Derive**: `deriveWorker(vm, adv_byte)` pops base function, builds derived Fn (builtin, lambda, or table entry); OPERAND hole for adverb.
    - **MakeDict**: `makeDictN(vm, n)` mirrors `doMakeDict` logic — promotes single keys/values directly, or constructs from array for n>1; OPERAND hole for N.
    - **Array SIMD stencils** (6): `stencilAdd_II`, `stencilSub_II`, `stencilMul_II`, `stencilAdd_FF`, `stencilSub_FF`, `stencilMul_FF`. Each calls `vm.jit_simd_array2` with the op baked in via OPERAND hole. Profile-guided re-JIT selects these on the second call when `type_hint` is 3 (I×I) or 4 (F×F). Workers use `@Vector(4,i32)`/`@Vector(4,f32)` NEON SIMD loops with scalar tail.

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

---

## ReleaseFast SIGILL crash (fixed)

**Symptom**: The JIT binary built with `-Doptimize=ReleaseFast -Djit=true` crashed with `illegal hardware instruction` (SIGILL) when running programs that use arithmetic.

**Root cause**: Two independent code-layout problems caused the scanner to copy an incomplete stencil into JIT memory, leaving unpatched sentinel words (`MOVZ X8, #0xDEAD`) as live instructions.

### Problem 1 — type-specialised Apply2 stencils (`stencilAdd_ii`, etc.)

In ReleaseFast, Zig compiles `specDyadInt` (the body shared by all six arithmetic stencils) with the fast path first and the type-guard failure path (`b.ne` → slow BLR path) appended after the NEXT hole sequence.  The layout is:

```
[fast path code]
MOVZ X8, #0xDEAD   ← first NEXT hole (scanner stops here)
MOVK X8, #0xBEEF, LSL16
MOVK X8, #0xCAFE, LSL32
MOVK X8, #0xBABE, LSL48
BR   X8
[slow path: STP ...; BLR handler; LDP ...]
MOVZ X8, #0xDEAD   ← second NEXT hole (not seen by scanWithFrame)
...
BR   X8
```

`scanWithFrame` scanned only to the first NEXT hole, so the `b.ne` from inside the fast path targeted code beyond the copied region → SIGILL on the branch.

### Problem 2 — Local and Const stencils (`stencilLocal`, `stencilConst`)

These stencils inline `stencilRef` via a switch on the value tag.  In ReleaseFast the switch arms generate a `b.ne` that jumps forward to an "else" block placed after the NEXT hole, creating the same escape pattern.

**Fix — three parts**:

1. **`hasEscapingBranch` detector** (`stencils.zig`): Before accepting a stencil, scan all instructions before the NEXT hole for any PC-relative branch (B.cond, CBZ, CBNZ, TBZ, TBNZ, B, ADRP, BL) whose target lies at or beyond the NEXT hole boundary.  If found, return `null` from `scan`/`scanWithFrame` so the emitter falls back to Phase 2.  This fixes `stencilLocal` and `stencilConst` — they fall to Phase 2 in ReleaseFast (still correct, just not Phase 1 speed).

2. **`scan2WithFrame` dual-NEXT-hole scanner** (`stencils.zig`): Scans for two consecutive NEXT holes and returns a `StencilInfo` where `next_offset` is the first hole and `branch_offset` is the second.  The full region between them (including the slow-path BLR code) is included in `size`, making all branches self-contained within the copied blob.

3. **Secondary NEXT hole patching in the emitter** (`emit.zig`): For non-branch stencils that have a `branch_offset` (i.e., type-spec Apply2 in ReleaseFast), the emitter registers the secondary hole as a pending branch whose `target_ip` is the very next bytecode instruction — so both holes are patched to the same successor address when that instruction is compiled.

**Registration** (`vm.zig`): Each type-spec stencil is now registered as:
```zig
.add_ii = s.scanWithFrame(@intFromPtr(&stencilAdd_ii))
          orelse s.scan2WithFrame(@intFromPtr(&stencilAdd_ii)),
```
`scanWithFrame` succeeds in Debug/ReleaseSafe (no escaping branches), `scan2WithFrame` is the fallback for ReleaseFast.

**Remaining limitation**: `stencilLocal` and `stencilConst` fall back to Phase 2 in ReleaseFast.  A `scan2WithFrame`-style fix for these would require capturing the multi-arm switch as a single blob, but the else block uses backward branches that already re-enter the main path — making the region shape irregular.  The correct fix is to split `stencilRef` into a dedicated helper rather than inlining its switch into every stencil.

---

## What can still be improved

### DUP not yet emitted by the optimizer

DUP exists as a bytecode opcode and JIT stencil but is never generated by the compiler pipeline.  The natural use case is consecutive duplicate reads: the pattern `Global X; Global X` (same index, adjacent) is currently handled by LICM as `Global X; AssignLocal T; Local T; Local T` (3 instructions + 1 stencil read).  DUP would let the lowerer emit `Global X; AssignLocal T; Local T; Dup` — same semantics, but only when the two uses are truly adjacent on the stack with no interleaving.  This is a narrow optimization; measure whether it matters before implementing.

### LICM scope: no loop detection

`liftInvariants` deduplicates within a linear IR scan.  It does not detect loop structures (back-edges in the BB graph) and therefore does not hoist globals that appear in only one BB per iteration.  For a lambda `{x * scale}` called N times by `each`, `scale` appears only once in the IR — the deduplication never fires.  True loop-invariant hoisting requires the caller (the adverb, not the lambda) to hoist, or a CPS-level transformation that fuses the adverb's dispatch loop with the lambda body.  This is a much larger change.

### CPS handler chain (fully frame-free Phase 2)

Still pending.  All ~15 handler signatures change to accept a `next` continuation pointer and tail-call it instead of returning.  The `STP x19,x30 / LDP x19,x30` prologue/epilogue disappears.  Phase 1 and Phase 2 become a uniform continuation chain.  This should be done after the `stencilRef` / `jit_ref` fix above, since both touch handler structure.

### Profile-guided stencil selection

`specDyad` now handles int×int and float×float but still falls to the worker for mixed-type calls (e.g., `.i` + `.f`).  A lightweight type-observation counter per call site (one byte per Apply2 site in the JIT cache) would let the emitter re-JIT with a more precisely matched stencil on the second call.  The JIT cache already stores one entry per lambda; extending it to a `(JitFn, observed_type_byte)` pair is minimal overhead.

### Stencil composition / generators

The Copy-and-Patch paper describes fusing adjacent stencils into one blob, removing the per-stencil `BR X8` hop.  Measure the overhead first: for `{x+y}` the chain is three stencils (Local, Local, specDyad) with two `BR X8` hops before the result.  If profiling shows the hops are significant (they are each ~1 cycle on Apple Silicon, so likely not), a composed "load-local-0; load-local-1; add" stencil would be the right tool.

### Array-level SIMD stencils

All current stencils operate on scalar values.  For element-wise array ops (`v + w` where both are integer vectors), NEON can process 2 × i64 or 4 × i32 per cycle.  Implementing this requires the JIT emitter to know at emit-time whether the operands are arrays — either through type profiling (inline caches, see above) or a dedicated `ApplyArray2` bytecode opcode emitted by the compiler when both operands are provably arrays.  This is the largest remaining performance gap for the array language use case.

## What was completed (Run 5) — recursion timeout + full stencil table

### Background

Two JIT tests timed out at 10 s under `-Doptimize=ReleaseFast -Djit=true`:

- **"recursion"** (`fib 10` → 55)
- **"list assign local"** (`{(a;b):...}[]`)

All other 217 tests were already passing.  The session was a continuation of prior work; the root cause had been identified but the fix not yet applied.

---

### Fix 1 — `noinline fn tryJit` (recursion timeout)

**Root cause**: In ReleaseFast, LLVM inlines `tryJit` into `applyFn`'s while loop (`while (self.vm.frames_len > prev_frames) { if (try self.vm.tryJit()) continue; ... }`).  After inlining, the optimiser notices that one branch of the inlined body always satisfies the `continue` condition and emits a `TBNZ` back-edge that bypasses the interpreter's `runOp` call entirely — creating an infinite spin loop for any lambda that enters the JIT.

**Fix**: Mark `tryJit` with `pub noinline fn tryJit`.  This forces the call to be a real BL, so the compiler can no longer fold the post-call branch into a back-edge.

**Effect**: The recursion timeout disappeared immediately.  219/219 tests passed after the fix (with the stencil table still in diagnostic state).'

---

### Fix 2 — `jump_false = null` (JumpFalse cannot be a Phase 1 stencil)

**Root cause**: When `stencilJumpFalse` is in Phase 1, the pending-branch patching at Phase-1 break time is architecturally incompatible with forward branches that target `Return` (rather than the else branch).

For a recursive function like `fib`:
```
ip  0: Local n
ip  2: Int 2
ip  4: Apply2 <        ← becomes lt_ii stencil
ip  6: JumpFalse +8    ← falls through to base case (ip 7), else jumps to ip 15
ip  7: Local n         ← base case: push n
ip  9: Jump +56        ← jump to Return at ip 65
ip 15: ...             ← recursive case (Global fib, Local n, Int 1, ...)
ip 65: Return
```

Phase 1 processes the JumpFalse stencil, then continues into the true-branch at ip 7 (`Local n`), then encounters `Jump +56`.  The emitter records the Jump's target (`Return` at ip 65) in `pending_branches`.  Phase 1 then breaks at ip 15 (Global = no stencil).

**Post-break patching sends ALL `pending_branches` entries to `handler_start`** (Phase 2's entry point, which starts at ip 15 — the recursive case).  The `Jump +56`'s pending branch is also patched to `handler_start`, so the base-case path (`Local n → NEXT hole`) gets sent to the recursive computation instead of to `Return`.

For `fib(10)`: the conditional check fires once (`condPop` confirms `10 < 2 = false`, correct), but the base case for all leaf calls of `fib(1)` and `fib(0)` incorrectly re-enters the recursive else-branch, producing wrong results.

**Fix**: `jump_false = null` (and `jump_true = null`).  Phase 2 handles these via `jhJumpFalse`/`jhJumpTrue`, which update `frame.ip` by the offset and let the interpreter dispatch correctly.

**The architectural constraint**: Phase 1 stencils with two NEXT holes (conditional branches) can only ever have *both* holes pointing forward into Phase 1, or have the else-hole be the `handler_start`.  They cannot safely handle any situation where the true-branch itself has further forward references that target a point *after* the Phase-1 break point.  Unless the emitter is redesigned to track per-pending-branch targets independently (and emit trampoline stubs for each), conditional stencils with fall-through code are unsafe in Phase 1 for anything other than the final "last branch before a terminal" pattern.

---

### Fix 3 — `scanTerminal` for `stencilReturn`

`scanAll` tries `scan3WithFrame → scan2WithFrame → scanWithFrame → scan`.  All four look for the NEXT hole sentinel (`MOVZ X8, #0xDEAD / MOVK … / BR X8`).  `stencilReturn` ends with `RET` (no NEXT hole), so all four return `null` and `return_` was silently left as `null` in the stencil table.

**Fix**: Register `return_` explicitly with `s.scanTerminal(@intFromPtr(&stencilReturn))`.  `scanTerminal` looks for `RET` and sets `is_terminal = true` so the emitter knows to end Phase 1 without entering Phase 2.

---

### Fix 4 — scan order: greediest first

The `scanAll` helper previously tried `scanWithFrame` before `scan3WithFrame`.  In ReleaseFast, SpecDyad stencils have three NEXT holes (int fast path, float fast path, slow BLR path — LLVM tail-duplicates the hole into each arm).  If `scanWithFrame` runs first it stops at the first hole, leaving two unpatched → SIGILL.

**Fix**: Reversed the order to `scan3WithFrame → scan2WithFrame → scanWithFrame → scan`, ensuring the greediest successful match wins.

---

### State of the JIT after Run 5

- **219/219 tests pass** with `-Doptimize=ReleaseFast -Djit=true --test-timeout 10s`.
- Full stencil table active:
  - **Phase 1 stencils**: `gap`, `dup`, `int_`, `const_`, `global`, `local`, `local_last`, `assign_local`, `apply1`, `apply2`, `drop`, `assign_global`, `make_list`, `derive`, `make_dict`, `return_` (terminal), `add_ii`, `sub_ii`, `mul_ii`, `lt_ii`, `gt_ii`, `eq_ii`, `add_II`, `sub_II`, `mul_II`, `lt_II`, `gt_II`, `eq_II`.
  - **Phase 2 only**: `jump_false`, `jump_true`, `call`, `tail_call`, `apply`, `make_partial`, `jump`.
  - **Interpreter fallback**: `amend`, `dmend`, `list_assign_global`, `list_assign_local`, `make_table`, `command`.
- `tryJit` is marked `noinline` to prevent the LLVM back-edge inlining bug.

---

### What could increase velocity

**1. Stencil shape validation at startup (Debug build)**

Add a comptime or runtime check that, for every registered stencil, all non-terminal instruction words that look like NEXT-hole sentinels have been patched by the emitter.  Currently a mis-registered stencil (wrong scan variant, wrong byte count) silently causes a SIGILL at the first hot call.  A startup validator that probes each stencil slot with a synthetic single-instruction chunk and checks that the output buffer contains no `0xBABECAFE` words would catch these in seconds rather than hours of binary-searching.

**2. Stencil disassembly in debug output**

The scanner (`scan`, `scanWithFrame`, etc.) knows the exact byte range it accepted.  A `--debug-jit` build flag that prints one line per stencil registration (`stencilAdd_ii: [0x…,+164] holes=[84,148,160]`) would have cut the SpecDyad 3-hole discovery time from ~2 hours to ~5 minutes.

**3. Document the pending-branch constraint explicitly**

The architectural rule — *Phase 1 stencils with two NEXT holes can only be safely used when the true-branch path has no forward references that survive past the Phase-1 break point* — should appear as a comment in `emit.zig` next to the post-break patching loop.  Without this, any future attempt to re-enable `jump_false` as a Phase 1 stencil will rediscover the bug from scratch.

**4. Targeted regression test for the JumpFalse base-case path**

A test of the form `assert (fib 3) = 2` is not enough — it also passes when the else-branch accidentally computes the right value.  A better sentinel is `assert (fib 1) = 1` and `assert (fib 0) = 1`, which specifically exercise the base-case path without any recursive accumulation masking the error.  Add these to the JIT-specific test suite as first-class regression guards.

---

## What can still be improved

### JumpFalse / JumpTrue as Phase 1 stencils

The two conditional branch stencils are currently Phase 2.  Making them Phase 1 would eliminate two `BL jhJumpFalse` calls per branch site, saving ~8 instructions per branch.  The prerequisite is redesigning the post-break pending-branch patching to track per-branch `target_ip` values and emit a small trampoline (or inline stub) for each distinct target rather than pointing all pending branches at `handler_start`.  Alternatively, a separate "branch stencil" compilation pass could split the lambda at each JumpFalse site and emit independent Phase 1 segments connected by direct BL chains — closer to the Copy-and-Patch paper's original approach.

---

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

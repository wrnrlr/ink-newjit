# Triage

Open items in the GPU shader compiler (`lib/dye.k`, `lib/spirv.k`,
`lib/gpu/gpu.zig`). These are enhancements / missing capabilities, not
correctness bugs — the compiler emits valid SPIR-V for everything it supports.
Each entry records the current behaviour, where it lives, and a fix sketch.

## GPU compiler — open

### 1. Constant deduplication

Every literal emits a fresh `OpConstant`; the same value used twice produces two
words. `compScalarLit` (`lib/dye.k`) and `compVecLit` (one `OpConstant` per
component) both do `r:newId[]; emitCon opConst[…]` unconditionally, as does the
IR path `xLoConst`. `Con` (the constant word buffer) is append-only with no
lookup. The only const-related optimisation is IR constant-folding + DCE,
neither of which deduplicates.

**Fix:** a value-keyed cache (e.g. a dict `bits!id`) consulted in
`emitCon opConst[…]` — return the cached id when the same type+bit-pattern was
already emitted. Reduces module size and pressure on id/pool limits.

### 2. SPIR-V 1.4 upgrade

Header is `0x00010300` (SPIR-V 1.3) in every emitter (vertex `buildMod`, all
compute variants). `OpEntryPoint` uses 1.3 subset-interface semantics — only
Input/Output builtins are listed (`iface: (,gidVar)` for compute; inputs +
single output for render); StorageBuffer / uniform-block / texture globals are
deliberately omitted.

**Fix:** bump the version word to `0x00010400` and extend the `OpEntryPoint`
interface to list *all* referenced global variables (storage buffers included),
recomputing the entry-point wordcount. Simplifies the compute interface and
unlocks later features.

### 3. Configurable compute workgroup size

Hardcoded to 64 in two places that must agree: `OpExecutionMode LocalSize
64,1,1` baked into all seven compute emitters (`compCompute`, `compCompute2`,
`compStencil*`, `compScatter`, `compGpN`) in `lib/dye.k`, and the host
workgroup-count division `(n+63)/64` in `gpuCompute`/`gpuCompute2`/`gpuDispatch`/
`gpuDispatchLoop` in `lib/gpu/gpu.zig`. `compCompute` takes no size argument.

**Fix:** thread a `wgSize` parameter through the compute emitters (into the
`OpExecutionMode` words) and through the host dispatch functions (replace the
literal `64`/`63` in the division). Allows tuning per GPU architecture.

### 4. Headless compute (no window)

Every compute entry point does `const r = g_renderer orelse return ki(0)`, and
`g_renderer` / the `GraphicsContext` (device + queue) is created *only* inside
`gpuRun`'s frame loop (`g_renderer = renderer` … `defer g_renderer = null`).
`GraphicsContext.create` appears nowhere else, so compute requires a live
`gpuRun` frame. The `-snap` path is still windowed (it just hides the window and
runs the normal render loop), so it does not satisfy compute-only-without-a-window.

**Fix:** a standalone headless device path — create a `wgpu` device+queue
without a swapchain/window and route the compute functions to it when no
`g_renderer` frame is active. Enables compute-only workflows.

### 5. Uniform buffers in compute shaders

Compute exposes storage buffers only. The host builds every compute binding as
`.binding_type = .storage`; all compute buffer vars use SPIR-V storage class
`12` (StorageBuffer), none use `2` (Uniform). The `params` binding in
`compStencilU` is a workaround — "just another storage buffer" (its own comment)
— so constants (array length, ω, …) are passed via a runtime-array storage
buffer, not a UBO. (The render path already emits true Uniform-class `Block`
structs, so this is a deliberate omission, not a missing capability.)

**Fix:** add a `.uniform` binding type in `gpuComputeNew`/the compute pipeline
and emit a `Block`-decorated struct in storage class `2` for compute constants,
mirroring `shader.vertexU`.

## GPU compiler — partial (sub-gaps)

- **i32 / bool as shader I/O types.** v3 is fully supported (incl. I/O). `bool`
  and `i32` exist in the type system (`Tbool`/`Ti32`) and are used internally
  (comparisons, loop counters, buffer indices, atomics), but `PtrIn`/`PtrOut`
  (`lib/spirv.k`) have no i32/bool entries, so they cannot yet be declared
  shader inputs/outputs. **Fix:** add i32/bool `PtrIn`/`PtrOut` pointer types.
- **Multiple fragment outputs (MRT).** The vertex→fragment varying interface is
  multi-output (`shader.vertexU` emits up to 4 varyings, each with its own
  `Location`), but fragment shaders emit a single Location-0 color output —
  `buildMod` has no loop over multiple outputs. **Fix:** generalise the
  fragment output var + `Location` decoration + store to a list of outputs.
- **User-facing int/float cast syntax.** `OpConvertSToF`/`OpConvertFToS`
  (`opI2f`/`opF2s`) exist and are exercised internally (index truncation,
  accumulator conversion) but there is no shader-source cast (`int x` / `float
  x`) in `mathFns`. **Fix:** bind cast names in the front-end to the existing
  convert stencils.

## Note on branching

`$[cond;a;b]` compiles via `OpSelect` (`compCond`/`compCondS`), which is
**eager** — both sides are always evaluated. Real `OpBranchConditional` +
`OpLoopMerge` + `OpPhi` machinery exists but is reserved for bounded loops
(`loopOpen`/`compWhile`/`compNdo`/`rsum`/`rmax`). Consequence: a branch cannot
guard a side effect (why `scatterAdd`'s out-of-range guard selects value `0`
rather than skipping the store). Promoting conditional *expressions* to real
control flow is possible but not currently needed for pure expressions.

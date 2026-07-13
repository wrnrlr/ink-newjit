# Triage

Open items in the GPU shader compiler (`lib/dye.k`, `lib/spirv.k`,
`lib/gpu/gpu.zig`). These are enhancements / missing capabilities, not
correctness bugs — the compiler emits valid SPIR-V for everything it supports.
Each entry records the current behaviour, where it lives, and a fix sketch.

## GPU compiler — open

### 1. Constant deduplication — DONE

`constId[t;v]` (`lib/dye.k`) now caches every scalar `OpConstant` in parallel
lists (`ConKeyT`/`ConKeyV` → `ConVal`) keyed by type id + encoded word, so an
identical literal emits a single `OpConstant` per module. `compScalarLit`,
`compVecLit` (component constants) and the IR path `xLoConst` all route through
it; the cache resets alongside `Con` at each module-reset site. Verified: four
`1.0` uses emit one `OpConstant`; i32 `0` and f32 `0.0` stay distinct (type in
the key); 85/85 golden (`test/spirv.k`) pass. Not routed: the one-per-compile
scaffold constants (`Kzero`, `uniKIdx`, `CKz`, `CScope`, loop constants), which
are already single-use — a minor missed dedup vs same-valued user literals, not
a correctness issue.

### 2. SPIR-V 1.4 upgrade — RECOMMENDED DEFER (not worth it yet)

Header is `0x00010300` (SPIR-V 1.3) in every emitter (vertex `buildMod`, all
compute variants). `OpEntryPoint` uses 1.3 subset-interface semantics — only
Input/Output builtins are listed (`iface: (,gidVar)` for compute; inputs +
single output for render); StorageBuffer / uniform-block / texture globals are
deliberately omitted.

**Assessment (why deferred):** the only concrete capability 1.4 adds *for us* is
`OpSelect` on composite/array types (1.3 restricts it to scalars/vectors), which
our `$[cond;a;b]` branching doesn't currently need. Bumping the version word is
**not** a free "compliance" win: 1.4 *requires* `OpEntryPoint` to list **all**
statically-referenced global variables (every storage class), so we'd have to
rewrite every emitter's `iface` to add the storage buffers / uniform blocks /
textures we legally omit under 1.3 — more work, not less — across ~12 emitters,
each a chance to produce an invalid module. Dawn/WebGPU already accepts our 1.3
modules. Net: a forced chore with real regression surface and no present payoff.

**Fix (when a real need appears):** bump the version word to `0x00010400` and
extend each emitter's `OpEntryPoint` interface to list all referenced global
variables, recomputing the entry-point wordcount. Do it the day something needs
OpSelect-on-composites (or a 1.4-only feature), not before.

### 3. Configurable compute workgroup size — DONE

The workgroup size is now the `wg` global in `lib/dye.k` (default 64), baked into
the `OpExecutionMode LocalSize` of all seven compute emitters. On the host,
`localSizeX` (`lib/gpu/gpu.zig`) parses `LocalSize` back out of the shader's
`OpExecutionMode` and divides the thread count by it in all four dispatch sites
(`gpuCompute`/`gpuCompute2` parse directly; `gpuComputeNew` stores it per
pipeline in `g_cwg`, used by `gpuDispatch`/`gpuDispatchLoop`). Because the host
reads the size from the shader itself, shader and dispatch stay in sync with no
FFI change — set `wg:128` before compiling to tune. Verified: default output
byte-identical (85/85 golden); `wg=16` over 100 elements dispatches 7 workgroups
and writes all 100 (a stale /64 divisor would drop the tail); resident
ping-pong path unaffected.

### 4. Headless compute (no window) — DONE

`gpuComputeRun[fn]` (`lib/gpu/gpu.zig`, exposed as `gpu.computeRun`) creates a
GPU device+queue with a hidden window (never shown), sets `g_renderer`, invokes
the k callback once, and tears the device down — all scoped via `defer`, so the
DebugAllocator asserts no leak. Compute (`gpu.runShader`, resident
`gpu.compileCompute`/`gpu.dispatch`) runs inside `fn` exactly as in a frame, with
no event loop. Results come back via a k global the callback assigns (`out:: …`),
mirroring `window.run`; the callback's return value is discarded (it is
VM-allocated and would trip the FFI return path's `c_alloc` free — that footgun
cost one debugging round). Verified end-to-end: one-shot double `1..5`→`2..10`
and resident element-wise double both correct, stderr leak-free.

Caveat: still creates a hidden GLFW window, so it needs a display/GLFW (headless
in the no-visible-window sense, like `-snap`) — not a truly surface-less device.
A genuine surfaceless path would be a small patch to the vendored
`patches/zgpu` `GraphicsContext.create` (skip surface+swapchain); deferred as
unnecessary for current use.

### 5. Uniform buffers in compute shaders — DONE

Compute can now bind a true UBO. `shader.computeU` (`compComputeU` in `lib/dye.k`)
emits an element-wise kernel `{[x;u] …}` where `u` is a uniform `vec4` — a
`Block`-decorated `struct{vec4}` in storage class `2` (Uniform) at set 0 binding
2, loaded via the render path's `loadUniMember`/`memberDecOne` helpers. On the
host: `gpuUniformNew` (`gpu.uniform`) creates a `.uniform`-usage buffer, and
`gpuComputeNewU` (`gpu.compileComputeU[spirv; nStorage]`) builds a pipeline with
nStorage storage bindings + one uniform binding at `nStorage`; the existing
`gpuDispatch` binds it positionally as the last handle. Constants (scale, bias,
length) now travel in a UBO instead of a runtime-array storage buffer. Verified:
`{[x;u] (x*u[0])+u[1]}` computes `3x+1` on `1..5`→`4 7 10 13 16`; updating the
UBO with `gpu.write` and re-dispatching gives `10x-2`→`8 18 28 38 48` without
touching the data buffer; no Dawn validation errors; 85/85 golden still pass.

Scope: one uniform `vec4` on the element-wise path (the common case — a handful
of scalars). Multi-member uniform structs or uniforms on the stencil/scatter
kernels would extend the same pattern (loop `memberDecOne`/`loadUniMember` over
N members) if needed.

## Runtime — open

### Find (`?`) over a boolean-vector left operand returns empty

```k-repl
 0 1 0b ? 1b     / expected: 1
                 / actual:   (empty)
 0 1 0b ? 1      / expected: 1  →  actual: (empty)
 0 1 0  ? 1b     / 1   (int left operand works)
 0 1 0  ? 1      / 1
```

`x?y` (Find) yields an empty result whenever `x` is a boolean vector (`` `B ``),
regardless of the right operand's type. An int-vector left operand works, so the
bug is specific to the `B` code path in Find (`src/primitive/verb/…`). Worked
around in `lib/dye.k` `constId` by using Where (`&mask`) instead of `mask?1b`.

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

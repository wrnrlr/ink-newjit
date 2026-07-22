# Issues

## 4. Slab free-size fragility — `Rc` header must stay 16 bytes (design note)

Confirmed sound as built. The epoch stamp added for ECS change-detection was
**not** a new `Rc` field — it is packed into the existing flags word
(`meta: u32` in `src/noun/rc.zig`: low 8 bits = `ArrayFlags`, high 24 bits =
epoch), so the header stays exactly 16 bytes (four `u32`s).

Why 16 matters: `array.deinit` (`src/noun/array.zig`) frees
`data_offset + cap*@sizeOf(T)` rather than the exact size `init` allocated. The
slab (`src/noun/slab.zig`) requires the same size on alloc and free, so this
reconstruction is exact only when `data_offset` is a multiple of every element
size (1/2/4/8/16). `data_offset = @sizeOf(Rc) = 16` satisfies that for all
element types, so it is correct — but it relies on the header being 16.

Growing `Rc` to 20/24 bytes would make `data_offset` not a multiple of the
`V`/dict element size; `cap = (total-data_offset)/size` would floor away a
remainder and `deinit` would free fewer bytes than allocated → DebugAllocator
"alloc 64 / free 56" mismatch. So the 16-byte constraint is load-bearing.

To make the header growable later, `deinit` must free the *actual* allocated
size, not reconstruct it: `init` passes sizes >1024 through unchanged while
`initWithCap` uses `ceilPowerOfTwo` for >1024, so `deinit` can't blindly
re-round — it must store the size class in the header or unify the two rounding
paths. Not blocking; the 16-byte constraint is fine. Documented so the next
header change doesn't rediscover this the hard way.

---

## 7. `walk.k` value-iteration amend returns `!type` — NOT A BUG (triage repro error)

The repro used `+/:` (each-**right**) which builds `W` as a `(#I, 4)` matrix, so
`+/x@W` reduces over the 64 outer rows → a length-4 vector, and the amend
`@[x;I(64);:;values(1)]` is a genuine length mismatch (`!type`). `test/walk.k`
itself uses `+\:` (each-**left**, line 21) → `W` is `(4, #I)`, so `+/x@W` sums the
4 neighbour rows → a length-64 vector matching `#I`, and the amend works. Verified:
`W:((-N),N,1,-1)+\:I` runs the whole relaxation cleanly. The amend path is fine.

```k
N:100;(r;c):1+!2#N-2;I:c+N*r;W:((-N),N,1,-1)+\:I   / +\: not +/:
f:{@[x;I;:;1.+.25*+/x@W]}
f (N*N)#0.0        / ok
```

---

## 11. `parse` of many files leaks IR-lowering scratch (Debug allocator)

Running the k language server (`tools/lsp.k`), which `parse`s every workspace
`.k` file to build a cross-file index, ends with a DebugAllocator leak report at
`src/compiler/compiler.zig:1025` (`lower`, the `offsets = alloc.alloc(usize, …)`
scratch). A single `parse` does not leak; it accumulates over many parses. Debug-
only (release uses `c_allocator`), so no functional impact, but the lowering
scratch for `parse`'d chunks isn't freed. Low priority.

---

## 20. `json.parse` columnarises arrays of uniform objects (design note / API footgun)

`json.parse "[{\"x\":1},{\"x\":2}]"` returns the **table/dict** `{x: 1 2}`, not a
list of two dicts (`lib/json/main.zig` → `convertArr` → `tryTable`). Deliberate
for data-shaped JSON (array-of-rows → columns), but a footgun when navigating API
responses: xAI's `choices:[…]` and Anthropic's `content:[…]`/`tool_use` arrays
don't index as lists. Mixed-key arrays fall back to a general list `L` (fine); only
uniform-key object arrays collapse. RESOLVED for callers who need lists: added
`json.list` (native `ParseJsonList`, a `promote=false` variant of `json.parse`)
that keeps arrays as general lists — `lib/llm.k`'s agent tool-use path uses it to
navigate `choices`/`content`/`tool_use`. `json.parse` still promotes (intentional
for data-shaped JSON). Streaming still uses the small `llm.jstr` line scanner
(avoids parsing per chunk). Left open as a design note: the default `json.parse`
promoting surprises API callers — consider documenting or flipping the default.

---

## 19. Upstream (Zig 0.16 std): `std.zip.EndRecord.findBuffer` doesn't compile

`std.zip.EndRecord.findBuffer` (`lib/std/zip.zig`) is declared
`fn findBuffer(buffer) FindBufferError!EndRecord` where
`FindBufferError = error{ ZipNoEndRecord, ZipTruncated }`, but its body does
`if (pos + @sizeOf(EndRecord) > buffer.len) return error.EndOfStream;` —
`error.EndOfStream` is not a member of the declared set, so the function fails to
compile the moment it is referenced:

```
zip.zig:113: error: expected type 'error{ZipNoEndRecord,ZipTruncated}!zip.EndRecord',
             found 'error{EndOfStream}'
```

Upstream bug in the Zig standard library (0.16.0), not ink. It only bites when
the function is actually instantiated, which is why most code never hits it.
Worked around in `lib/zip/main.zig` (`findEnd`) by locating the End-Of-Central-
Directory record ourselves — `std.mem.lastIndexOf(buf, &zip.end_record_sig)` then
`@ptrCast(*align(1) const zip.EndRecord)` (little-endian host assumed). The rest
of the in-memory parse reuses `std.zip`'s `align(1)` extern struct layouts
(`CentralDirectoryFileHeader`, `LocalFileHeader`), which are fine. Revisit if a
future Zig fixes `findBuffer` (either the declared error set gains `EndOfStream`
or the body stops returning it) — the workaround can then be dropped.

---

# GPU shader compiler

Enhancement tracking for the SPIR-V shader compiler (`lib/dye.k`, `lib/spirv.k`,
`lib/gpu/gpu.zig`). These are missing capabilities, not correctness bugs — the
compiler emits valid SPIR-V for everything it supports.

## Open

### SPIR-V 1.4 upgrade — RESOLVED via the Vulkan/MoltenVK migration (2026-07-13)

**Outcome:** SPIR-V 1.4 is no longer blocked — it works on the new Vulkan/MoltenVK
backend (`-Dgpu-backend=vulkan`, `INK_SPV14=1`). The whole compute/nn stack runs on
genuine 1.4, bit-identical to 1.3. See `.plan/tasks.md` "GPU: Dawn → Vulkan
migration" and `doc/design/vulkan-migration.md`. The analysis below remains correct
for *WebGPU/Dawn* (which still refuses 1.4) and is why the migration was needed.

### SPIR-V 1.4 on Dawn — BLOCKED (unchanged; Dawn's Tint reader caps at 1.3)

Header is `0x00010300` (SPIR-V 1.3) in every emitter (vertex `buildMod`, all
compute variants). `OpEntryPoint` uses 1.3 subset-interface semantics — only
Input/Output builtins are listed (`iface: (,gidVar)` for compute; inputs +
single output for render); StorageBuffer / uniform-block / texture globals are
deliberately omitted.

**Tried it — Dawn rejects 1.4 outright.** Bumping the version word to
`0x00010400` and expanding every emitter's `OpEntryPoint` interface to list all
referenced global variables (the two changes 1.4 requires) was implemented and
tested. The prebuilt Dawn (`dawn_aarch64_macos` lazy dep) refuses the module
before running it:

    Tint SPIR-V reader failure: Invalid SPIR-V binary version 1.4 for target
    environment SPIR-V 1.3 (under Vulkan 1.1 semantics).

Dawn's ingestion target here is pinned to SPIR-V 1.3 / Vulkan 1.1, so *any* 1.4
module is invalid regardless of correctness. Both changes were reverted.

**A Dawn rebuild does NOT unblock this (investigated 2026-07-13).** The block is
not a target-env knob in this particular prebuilt — it is inherent to the WebGPU
raw-SPIR-V ingestion path. ink hands SPIR-V to Dawn via
`ShaderModuleSPIRVDescriptor` (`lib/gpu/gpu.zig`), which routes through Tint's
**SPIR-V reader**. That reader validates against the **Vulkan 1.1** environment
(`spirv-val --target-env vulkan1.1`), which caps input at **SPIR-V 1.3** (Vulkan
1.1↔SPIR-V 1.3; ingesting 1.4 would require the Vulkan 1.2 env). Dawn/Tint's own
docs state "SPIR-V 1.4 and later are not supported in Tint's SPIR-V reader." So
*no* Dawn version — rebuilt or newer prebuilt — accepts a 1.4 module through this
API. (The 1.4 support that shipped on Android/ChromeOS is Tint's *writer*,
WGSL→SPIR-V for the Vulkan backend — opposite direction, moot on macOS/Metal.)
Also: the vendored `dawn_aarch64_macos` prebuilt (michal-z) has no build newer
than July 2023, so there is no drop-in newer prebuilt anyway.

**Assessment:** the only capability 1.4 adds *for us* is `OpSelect` on
composite/array types (1.3 restricts it to scalars/vectors), which our
`$[cond;a;b]` branching doesn't need. Combined with the reader constraint above,
this is **WON'T-DO**, not merely deferred.

**Only routes that could ever run 1.4-era features (both out of scope):**
(a) emit or transpile to **WGSL** instead of raw SPIR-V (no version cap, but
rewrites the GPU back-end); (b) drop WebGPU for a raw **Metal/Vulkan** backend
(abandons Dawn). Neither is justified for an unused feature. See `.plan/tasks.md`.

### i32 / bool as shader I/O types

v3 is fully supported (incl. I/O). `bool` and `i32` exist in the type system
(`Tbool`/`Ti32`) and are used internally (comparisons, loop counters, buffer
indices, atomics), but `PtrIn`/`PtrOut` (`lib/spirv.k`) have no i32/bool entries,
so they cannot yet be declared shader inputs/outputs. **Fix:** add i32/bool
`PtrIn`/`PtrOut` pointer types.

### Multiple fragment outputs (MRT)

The vertex→fragment varying interface is multi-output (`shader.vertexU` emits up
to 4 varyings, each with its own `Location`), but fragment shaders emit a single
Location-0 color output — `buildMod` has no loop over multiple outputs. **Fix:**
generalise the fragment output var + `Location` decoration + store to a list of
outputs.

### User-facing int/float cast syntax

`OpConvertSToF`/`OpConvertFToS` (`opI2f`/`opF2s`) exist and are exercised
internally (index truncation, accumulator conversion) but there is no
shader-source cast (`int x` / `float x`) in `mathFns`. **Fix:** bind cast names
in the front-end to the existing convert stencils.

### Branching is eager `OpSelect` (no real control flow for expressions)

`$[cond;a;b]` compiles via `OpSelect` (`compCond`/`compCondS`), which is **eager**
— both sides are always evaluated. Real `OpBranchConditional` + `OpLoopMerge` +
`OpPhi` machinery exists but is reserved for bounded loops
(`loopOpen`/`compWhile`/`compNdo`/`rsum`/`rmax`). Consequence: a branch cannot
guard a side effect (why `scatterAdd`'s out-of-range guard selects value `0`
rather than skipping the store). Promoting conditional *expressions* to real
control flow is possible but not currently needed for pure expressions.

## Namespace member written only externally is invisible to internal readers (file-load)
A `\d ns` member that is only assigned from OUTSIDE the block (`ns.member:: v`) and read INSIDE by
bare name resolves to a DIFFERENT global than the external write, when the file is loaded via `2:`
or run as the main script. Repro: file `\d world; el:0.; probe:{[] el}; \d`; then `world.el::5`;
`world.probe[]` → 0 (should be 5). Inline it returns 5. Adding any internal write (`el::…` in a
namespace fn) makes both align. Likely compile-time name-mangling treating read-only members as
file-private. Workaround: set members via an internal setter fn. Found building demo/timer.k.

## `>=` misparse in lib/pga.k:39 (found by tools/klint.k)
`pgaLDotF: … & pgaGrd[pgaBj]>=pgaGrd[pgaAi]` — k has no `>=`; this parses as
`pgaGrd[pgaBj] > (=pgaGrd[pgaAi])` (a monadic `=` group of the RHS), not the intended
`gradeB >= gradeA`. The left-contraction grade filter is therefore wrong. Fix:
`~(pgaGrd[pgaBj]<pgaGrd[pgaAi])`. Not touched here (GA logic is subtle and lacks a quick oracle in
this session; unrelated to the UI work). Surfaced by the new `<=`/`>=` linter `tools/klint.k`
(`make lint`) — 2026-07-22.

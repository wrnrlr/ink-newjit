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

## 5. Concatenating a typed vector with `()` upcasts it to a boxed `` `L `` — FIXED

**Fixed** (`src/primitive/verb/concat.zig`): the right-empty form `x,()` is now
identity — a typed vector keeps its type (`` `a`b,() `` → `` `S ``) and an atom
enlists to its typed 1-vector (`1,()` → `,1` as `` `I ``), matching ngn/k. Dict
keys/env merges built with `(k,())!(v,())` index correctly again. Scope note: only
the *right-empty* form is special-cased; the *left-empty* `(),x` keeps its old
"box into a general list" behaviour — the GPU shader compiler's word-list assembly
(`lib/dye.k`, `,/(hdr;…)`) relies on `()` on the left forcing a general list, and
changing it regressed the whole `kk.compile` path. The reported cases (all
right-empty) are covered.

```k-repl
 (`a`b),()
(`a;`b)                 / `L (boxed general list), not `a`b (`S)
 ((`a`b),())!1 2
 ... lookup by `a fails ...
```

`x,()` should be identity (append nothing), but joining a typed vector
(symbol vector `` `S ``, int vector `` `I ``, …) with the empty general list `()`
re-types the result to a boxed general list `` `L ``. Two downstream surprises:

- A dict built from such keys no longer matches plain-symbol lookups:
  `((`a`b),())!1 2` indexed by `` `a `` returns empty (the keys are boxed
  symbols, not a `` `S `` vector).
- `,/sections` where one branch is `()` (e.g. an `$[cond; vec; ()]`) boxes the
  whole razed result to `` `L ``.

Found while building `lib/spirv.k`'s `VertexShaderU`: a `(keys,())!(vals,())`
env-merge silently lost every binding, and an assembly section list with an
empty branch produced a `` `L `` SPIR-V word list that the GPU host's `kip()`
then rejected (a uniform mesh pipeline silently failed → black screen, no
error). Worked around by guarding the empty case
(`$[n>0; (a,b)!(c,d); a!c]`) and using `!0` (empty `` `I ``) rather than `()`
for empty integer sections. The clean fix is for dyadic `,` (Join) to treat an
empty operand as identity and preserve the non-empty operand's type
(`src/primitive/verb/` join path). Related to the general-list dict-join issue
already noted for `lib/recs.k`.

---

## 6. List *literal* caps at 255 elements (`MakeList` count is `u8`) — FIXED

**Fixed**: the `MakeList` count is now a `u16` (opcode + 2 bytes), so a list literal
can hold up to the VM stack depth (2048) instead of panicking above 255. The count
is written/read in FOUR places that must stay in lockstep — `compiler.zig`
(`lowerInst` write16 + `instSize` → 3), `vm.zig` `doMakeList` (`read16`), `tape.zig`
`instrSize` (→ 3, used by `buildBlocks`), and `disasm.zig` (`readU16`). Missing the
`tape.zig`/`buildBlocks` one desyncs basic-block boundaries and corrupts every chunk
with control flow (invalid-enum panic) — the size decoder there is independent of the
compiler's.

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

## 10. Namespace member forward-reference resolves to blank under script eval — RESOLVED

**Resolved**: `evalStream` (`src/cmd/repl.zig`) now calls
`compiler.prescanGlobals` over the whole file before compiling statement-by-
statement, pre-registering every qualified top-level target. A member that
references another member defined *later* in the same `\d ns` block resolves
correctly under both `ink file.k` and the autoloader now. Verified with a
forward-ref namespace file (`ns.foo` → `bar` defined below → 105).

---

## 11. `parse` of many files leaks IR-lowering scratch (Debug allocator)

Running the k language server (`tools/lsp.k`), which `parse`s every workspace
`.k` file to build a cross-file index, ends with a DebugAllocator leak report at
`src/compiler/compiler.zig:1025` (`lower`, the `offsets = alloc.alloc(usize, …)`
scratch). A single `parse` does not leak; it accumulates over many parses. Debug-
only (release uses `c_allocator`), so no functional impact, but the lowering
scratch for `parse`'d chunks isn't freed. Low priority.

---

## 12. Raw byte write (`1:`) rejects a single-char atom — FIXED

**Fixed** (`src/primitive/verb/io.zig`): `WriteBytes` now has `_s_c`/`_C_c`/`_i_c`
entries and an `ybytes` helper that treats a `c` char atom as a 1-byte write.
`` `stdout 1: "a" `` writes the byte; the `,"a"` enlist workaround is no longer
needed. Applies to stdio handles, files, and sockets.


```k-repl
 `stdout 1: "ab"      / writes the 2 bytes
 `stdout 1: "a"       / -> !type   ("a" is a char ATOM, not a `C` vector)
 `stdout 1: ,"a"      / workaround: enlist to a 1-char `C` vector
```

The `1:` WriteBytes verb only dispatches on `C` (char vector) for the raw-write
paths (`_s_C`/`_C_C`/`_i_C` in `src/primitive/verb/io.zig`), so writing a single
character — which lexes as a char atom `c`, not `C` (single-char string is an
atom) — is a `!type`. Applies to the stdio handles (`` `stdout ``/`` `stderr ``),
files, and sockets. Harmless for the LSP (frames are multi-char) but surprising;
the fix is to accept a `c` atom as a 1-byte write in the byte-IO dispatch.
Workaround: enlist with `,`.

---

## 14. A keyword-verb param name is silently mishandled (dropped / mis-parsed) — FIXED

**Fixed** (`src/parser/parser.zig`, `parseArgList`): a parameter named after one of
the four remaining keyword verbs (`in has mod div`) now raises a clean
`!parse_error: UnexpectedToken` instead of silently dropping/mis-parsing. The lexer
always tokenises these as verbs, so full shadowing would need scope-aware lexing (a
much deeper change); rejecting loudly kills the silent-miscompile. The removed
math/monadic names (`count first last sqrt parse …`) are now prelude *identifiers*,
so they are fine as param names — only the 4 genuine keyword verbs are rejected.
Workaround unchanged: use `cnt`, `src`, `elem`, …


```k-repl
 {[count;buf] count,buf}[100;3]      / → a DICT (`!), not `100 3`
 {[in;x] in,x}[1;2]                  / `in` dropped: arg mapping shifts
```

A lambda parameter named the same as a keyword verb (`in count first last has
mod div sqrt sqr exp log sin cos abs parse exec depth epoch …`) is not treated as
a plain local: the reference lexes as the *verb*, so `count,buf` parses as the
`count` verb applied (yielding a dict) rather than "join the two params", and
`in` is dropped from the parameter list entirely (shifting every later param /
the arg→slot mapping). No error — just wrong values. Cost real time twice: an
`in`-named kernel param in `lib/spirv.k`'s GpKernel silently shifted its env, and
a `count`-named param in `lib/instancing.k`'s `DrawResident` built a dict instead
of the `(count,buf)` vector the FFI expected (→ a no-op draw / black screen). Fix:
either reject keyword names for params at parse time, or bind params before verb
lookup. Workaround: never name a param after a keyword verb (use `cnt`, `src`, …).

---

## 15. `f +x` (function juxtaposed with a monadic-verb-prefixed arg) parses `+` as dyadic — NOT A BUG

**Not a bug** — this is standard k parsing and ngn/k agrees: a verb glyph between
two nouns is dyadic, so `f +x` is `f + x` (add), not `f (+x)`. ngn/k gives the
same `'type` on `f +(2 2#1 2 3 4)`. (`f -3` works in both because `-3` with a
leading space is a negative literal, so `f` applies to `-3`.) The idiom is to
parenthesise a monadic operand: `f (+x)`, `f (-x)`, `f (|x)` — or bind it to a
temp first. Left as a documented gotcha (already in AGENT.md), not a fix.

```k-repl
 tcol:+(nTris;3)#triIds; av:triArea tcol     / correct: av = per-triangle areas
 av:triArea +(nTris;3)#triIds                / dyadic add (as in ngn/k) — use f (+x)
```

---

## 16. Indexed-amend `x[i]:v` inside a lambda breaks the global (needs `::` / `@[]`) — RESOLVED

**Resolved**: the collapse is gone. Inside a lambda, `gIm[0 19]::0.` (deep-indexed
`::`) now correctly amends the global in place at a multi-element index list
(`#gIm` stays 400, indices 0 & 19 zeroed), and the single-colon `gIm[0 19]:0.` no
longer clobbers the global to size 1 — it just makes a local copy, which is the
expected k semantics (use `::` to write the global). The `x::@[x;idx;:;v]` form
also works. Verified with the corner-mass pinning repro.


```k-repl
 gIm::(400)#1.
 f:{[] gIm[0,19]:0.}   f[]   /  #gIm → 1  (gIm clobbered; single `:` makes a broken local)
 f2:{[] gIm[0,19]::0.} f2[]  /  #gIm → 1  (the `x[i]::v` deep-assign also collapses on a multi-index)
 f3:{[] gIm::@[gIm;0,19;:;0.]} f3[]  / correct: #gIm → 400, indices 0 & 19 zeroed
```

The `x[idx]:v` amend sugar amends the global correctly at top level, but inside a
function the single-colon form creates a broken local (`#gIm`→1, subsequent reads
error), and even the `::` deep-indexed-assign collapses when `idx` is a
multi-element index list. The reliable form inside a function is the explicit
amend `x::@[x;idx;:;v]`. Surfaced pinning corner masses (`gIm[0,nCols-1]:0.` /
`im0[0,W-1]:0.`) in `demo/clothbench.k`'s size-parameterised setup functions —
the pins silently corrupted the mass array. Same family as the "`::` for globals
in lambdas" note, but specific to the *indexed* amend with a list index.

---

## 17. `` `c$-1 `` panics instead of erroring (cast to char from a negative int) — FIXED

**Fixed** (`src/primitive/verb/cast.zig`, `numCast` i32→u8 arm): now
`@truncate(@as(u32, @bitCast(v)))` — an out-of-range or negative int wraps into the
byte (`` `c$-1 `` → char 0xff) like the u32→c path, instead of panicking. Applies to
both the scalar and vector char casts (both route through `numCast`).

---

## 18. Find (`?`) over a boolean-vector left operand returns empty — FIXED

**Fixed** (`src/primitive/verb/find.zig`): the `Find` struct had no `_B_*` entries
(bool-vector left) and no `_I_b`/`_I_B`/`_F_b`/`_F_B` entries (bool right against an
int/float vector), so those combinations hit the type-error fallback. Added a
`findBool` kernel that coerces the bool operand(s) to the shared numeric family
(bools are 0/1; float when the other side is float) and routes to the int/float find
kernels. Now `010b?1b`, `010b?1`, `0 1 0?1b`, `0. 1. 0.?1b` all find at the right
index.

Note: the triage's `0 1 0b` is actually an int vector — a space-separated mixed
literal promotes to `` `I `` — the real `B` literal is `010b` (no spaces). Both the
`B`-left and bool-right-against-`I/F` paths are covered now.

```k-repl
 010b ? 1b        / 1
 0 1 0 ? 1b       / 1  (int left, bool right)
```

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

## Resolved

### Constant deduplication — DONE

`constId[t;v]` (`lib/dye.k`) caches every scalar `OpConstant` in parallel lists
(`ConKeyT`/`ConKeyV` → `ConVal`) keyed by type id + encoded word, so an identical
literal emits a single `OpConstant` per module. `compScalarLit`, `compVecLit`
(component constants) and the IR path `xLoConst` route through it; the cache
resets alongside `Con` at each module-reset site. Verified: four `1.0` uses emit
one `OpConstant`; i32 `0` and f32 `0.0` stay distinct (type in the key); 85/85
golden (`test/spirv.k`) pass. Not routed: the one-per-compile scaffold constants
(`Kzero`, `uniKIdx`, `CKz`, `CScope`, loop constants), already single-use.

### Configurable compute workgroup size — DONE

The workgroup size is the `wg` global in `lib/dye.k` (default 64), baked into the
`OpExecutionMode LocalSize` of all seven compute emitters. On the host,
`localSizeX` (`lib/gpu/gpu.zig`) parses `LocalSize` back out of the shader's
`OpExecutionMode` and divides the thread count by it in all four dispatch sites
(`gpuCompute`/`gpuCompute2` parse directly; `gpuComputeNew` stores it per pipeline
in `g_cwg`, used by `gpuDispatch`/`gpuDispatchLoop`). Because the host reads the
size from the shader itself, shader and dispatch stay in sync with no FFI change —
set `wg:128` before compiling to tune. Verified: default output byte-identical
(85/85 golden); `wg=16` over 100 elements dispatches 7 workgroups and writes all
100 (a stale /64 divisor would drop the tail); resident ping-pong unaffected.

### Headless compute (no window) — DONE

`gpuComputeRun[fn]` (`lib/gpu/gpu.zig`, exposed as `gpu.computeRun`) creates a GPU
device+queue with a hidden window (never shown), sets `g_renderer`, invokes the k
callback once, and tears the device down — all scoped via `defer`, so the
DebugAllocator asserts no leak. Compute (`gpu.runShader`, resident
`gpu.compileCompute`/`gpu.dispatch`) runs inside `fn` exactly as in a frame, with
no event loop. Results come back via a k global the callback assigns (`out:: …`),
mirroring `window.run`; the callback's return value is discarded (it is
VM-allocated and would trip the FFI return path's `c_alloc` free). Verified
end-to-end: one-shot double `1..5`→`2..10` and resident element-wise double both
correct, stderr leak-free. Caveat: still creates a hidden GLFW window, so it
needs a display/GLFW (headless in the no-visible-window sense, like `-snap`) — a
truly surface-less device would be a small patch to `patches/zgpu`'s
`GraphicsContext.create` (skip surface+swapchain), deferred as unnecessary.

### Uniform buffers in compute shaders — DONE

`shader.computeU` (`compComputeU` in `lib/dye.k`) emits an element-wise kernel
`{[x;u] …}` where `u` is a uniform `vec4` — a `Block`-decorated `struct{vec4}` in
storage class `2` (Uniform) at set 0 binding 2, loaded via the render path's
`loadUniMember`/`memberDecOne` helpers. On the host: `gpuUniformNew`
(`gpu.uniform`) creates a `.uniform`-usage buffer, and `gpuComputeNewU`
(`gpu.compileComputeU[spirv; nStorage]`) builds a pipeline with nStorage storage
bindings + one uniform binding at `nStorage`; the existing `gpuDispatch` binds it
positionally as the last handle. Verified: `{[x;u] (x*u[0])+u[1]}` computes
`3x+1` on `1..5`→`4 7 10 13 16`; updating the UBO with `gpu.write` and
re-dispatching gives `10x-2`→`8 18 28 38 48` without touching the data buffer; no
Dawn validation errors; 85/85 golden still pass. Scope: one uniform `vec4` on the
element-wise path; multi-member structs or uniforms on stencil/scatter kernels
would extend the same pattern (loop `memberDecOne`/`loadUniMember` over N members).

## converge `/` with a NAMED function silently no-ops (found 2026-07-18) — RESOLVED
**Resolved**: converge over a named lambda now iterates to the fixed point.
Verified `f:{$[x<10;x+1;x]}; f/ 0` → 10 (same as the inline `{…}/ 0`). No longer
returns the argument degenerately.

## char-base join adverb crashes on a general-list arg (found 2026-07-19) — FIXED
**Fixed** (`src/primitive/adverb/join.zig`): the char-separator join (`sep/parts`)
now validates that every part is a `c`/`C` char atom/vector up front and returns
`!type` for a non-string element (e.g. a boxed general list), instead of
dereferencing `p.c` on a `.L` value and panicking. `test/kkc.k` runs clean (44/44).

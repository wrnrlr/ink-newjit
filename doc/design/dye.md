# dye: splitting the shader compiler from SPIR-V encoding

Status: Phase 0 + Phase 2 landed. Phases 1, 3, 4 planned.

`dye` is to `ink` what `q` is to `k` in kdb+: a language layer built on the array
core. Where ink is the CPU array language + VM, **dye is the compiler that lowers
ink lambdas to other targets** — today SPIR-V shaders, later ink-VM bytecode. The
goal of this work is to separate three things that were tangled in the old
1400-line `lib/spirv.k`:

1. the **language front-end** (parse an ink lambda → CST → walk it),
2. the **compiler / optimizer** (types, constants, IR, peephole),
3. the **instruction encoding** (emit the actual SPIR-V words).

Separating them lets us (a) reuse the front-end/optimizer as a first pass over k
destined for the CPU, (b) make the shader compiler more robust by tracking global
constants/variables in one place, and (c) open the door to monomorphic call-site
specialization.

## Two papers, two ideas

- **Copy-and-patch** (`doc/papers/copy-and-patch.md`): a compiler is a *stencil
  library* (partial binary implementations with holes) plus a *code generator*
  that stitches stencils together and patches the holes. `lib/spirv.k`'s `op*`
  functions are exactly stencils — each returns the words for one instruction with
  the result-id / operand-id holes left for the caller. **So: the `op*` set is the
  stencil library; dye is the code generator.**
- **Tiramisu** (`doc/papers/baghdadi_2019_tiramisu.md`): keep a *multi-layer IR*
  that separates the architecture-independent algorithm from per-target lowering,
  scheduling, and data/comm management. **So: dye's front-end + a neutral IR is the
  target-independent layer; SPIR-V (and, later, ink bytecode) are back-ends.**

## Module layout

```
lib/spirv.k    the stencil library — PURE, STATELESS.
               reserved type ids, type-id lookup tables (Tid/PtrIn/PtrOut/LitTid),
               and one op* per SPIR-V instruction. No globals mutated. ~110 lines.

lib/dye.k      the dye compiler. Owns:
                 - module state: Nid / Con / Buf + newId / emitCon / emitBuf
                 - CST access: parse → Cst table, kKind/kVal/kF/lamOf…
                 - type system: isVecTy/ncVec/binRty + the math-fn name lists
                 - node walkers: compNode + comp* (one per CST kind)
                 - in-kernel control flow: loopOpen/loopClose/compRsum/compNdo/…
                 - module assembly: buildMod + the *One decoration helpers
                 - public entry points: FragmentShader / VertexShader /
                   ComputeShader / StencilShader* / GpKernel / …

lib/prelude.k  (Phase 1) CPU builtins: bind ink names to intrinsic symbols
               (sin:`sin@, sort:{x@<x}, …). The GPU builtins live in lib/dye.k.
```

**Load order.** `dye.k` cannot `2:"lib/spirv.k"` itself: a `2:` load *inside* a
`2:`-loaded file underflows the VM stack (the "nested `2:`" bug — see
`lib/nn.k`'s load note; it panics in `vm.zig pop()`). So callers load the encoder
first, then the compiler, at their own top level:

```
2: "lib/spirv.k"; 2: "lib/dye.k"; 2: "lib/gpu.k"
```

All ~27 GPU demos and `test/spirv.k` were repointed accordingly. Fixing the
nested-`2:` VM bug (Phase 3+) would let `dye.k` pull in its own dependency and
collapse this back to a single load line.

**Verification.** The split is behavior-preserving: `test/spirv.k` (the whitebox
golden) produces byte-identical output before and after, and the compute /
fragment / mesh shader paths render on-device (`test/compute.k`, `test/circle.k`,
`test/pbr.k`).

## The intrinsic registry (single source of truth)

The knot behind every goal here is that "math functions" are spelled out in ~5
disconnected places:

| Class | Examples | Where (today) |
|---|---|---|
| grammar keyword verbs | `sqrt sqr exp log sin cos abs` | `lexer.zig` KEYWORD_OPS + `Op1` enum + `calc.zig` kernels |
| fused KOp micro-ISA | `sqr sqrt exp log sin cos` (not `abs`) | `tape.zig` KOp + `compiler.zig` fuseMaps |
| magic symbols | `` `asin `acos `atan `atan2 `` | `syms.zig` string-match over `std.math` |
| GPU math | `pow min max dot cross step clamp mix smoothstep` + all the above | `lib/dye.k` `mathFns` lists + `lib/spirv.k` `op*` |

`src/primitive/intrinsic.zig` is the canonical table keyed by the intrinsic's
**symbol name**, recording for each: arity, its CPU `Op1`/`Op2` (if any), whether
it fuses into a KOp, whether it's a grammar keyword today, and its GLSL.std.450
ext-inst number for the GPU. A parity test in `src/test.zig` asserts the table
stays faithful to the live enums, so later phases can *generate* the lexer keyword
list / syms dispatch / fuse map / dye lowering from it instead of hand-syncing.

## Roadmap

### Phase 0 — foundation (DONE)
- This document.
- `src/primitive/intrinsic.zig` canonical table + parity test (additive; nothing
  consumes it yet).

### Phase 2 — encoder/compiler split (DONE)
- `lib/spirv.k` reduced to the pure stencil library; `lib/dye.k` is the compiler.
- Demos/tests repointed. Byte-identical golden output; on-device render verified.

### Phase 1 — unify math on symbols; remove keyword verbs from the grammar (DONE)
- Dropped `sqrt sqr exp log sin cos abs` from `lexer.zig` KEYWORD_OPS (kept the
  `Op1` members and their calc.zig kernels).
- `syms.zig` now routes any registry intrinsic that has an `Op1` (`` `sqrt@x `` …)
  through the *same* `dispatch1(Op1)` kernel as the old verb — so types match
  exactly (integer-closed `sqr`/`abs` stay integer, unlike the f32-widening
  `mapUnary` used for `asin`/`acos`/`atan`/`atan2`).
- `lib/prelude.k` binds the ink names to juxtaposition lambdas (`` sin:{`sin x} ``,
  …) — deliberately NOT the `` `sin@ `` projection: `` `sym@<int-scalar> `` hits a
  pre-existing `@`-dyad dispatch bug (routes to the `2:` loader — see `doc/bug.md`),
  whereas `` `sin x `` routes Call.apply → syms.apply and handles every int/float
  scalar and vector. Loaded into every VM at init (`VM.create` → `loadPrelude`,
  best-effort, top-level so no nested-`2:`). `sin x` / `sqrt 4 9` / `abs 3` behave
  as before; `sqr`/`abs` stay integer-closed.
- The registry's `keyword` flag became `prelude` (the CPU math surface); a
  `src/test.zig` parity test keeps `intrinsic.zig` faithful to the enums and the
  11-name prelude list. Existing unit tests (`sqrt 4 9`, `sqr 2 3`, `sin 0.0`, …)
  pass unchanged; `test/spirv.k` golden + earth/pbr/clothgpu/relax demos verified.

  **Two known trade-offs (deliberate, documented):**
  1. *`-` adjacency*: a math name is now a noun, so `abs -4` parses as `abs - 4`
     (dyadic subtract), not `abs(-4)`. Use `abs[-4]`. Zero existing k files used the
     regressing pattern; one unit test was updated.
  2. *No fusion yet*: `sin x` is a projection-apply of a global, so it does not fuse
     into an elementwise `KOp` kernel (it still runs one vectorised `dispatch1`).
     The compile-time peephole that recognises an intrinsic symbol / a global bound
     to `` `f@ `` and lowers it to `Op1`/`KOp` — the requested monomorphic call-site
     optimization — is deferred to **Phase 3** (it wants the IR seam + compile-time
     global-value inspection to respect user shadowing).

### Phase 3

**Intrinsic peephole — monomorphic call-site lowering (DONE).** The compiler
(`compileApposit` + `compileApply`) now recognises a **literal intrinsic symbol**
applied to args and lowers it straight to the `Op1`/`Op2` kernel:

```
`sin a          → Apply1 sin
`sqrt 1.0+a     → FusedMap [Col0 Col1 Add0 Sqrt0]     (add+sqrt fused into one KOp)
`sqr 2 3        → Apply1 sqr                          (integer-closed)
```

Because a literal symbol can't be shadowed, this needs no scope analysis. It makes
every lib/prelude.k body (`{`sin x}`) compile to the fast opcode instead of a
`syms.apply` string-match, fuses explicit-symbol math with adjacent elementwise
ops, and sidesteps the `@`(sym,int-scalar) dispatch bug (the intrinsic never
reaches `dispatch2`). Verified via `ink disasm`; full suite + golden + demos green.

**Name-level fusion — Level B (DONE), built on single/double-bind.** The strict rule
"`:` at global scope = **constant**, `::` = **variable**" is what makes constant
name-resolution sound, so we lean on it: a name bound at global scope with a SINGLE
colon to a monadic intrinsic wrapper (`` sin: {`sin x} ``, exactly the prelude form)
is recorded in the compiler as an **alias** `name → Op1` (`Compiler.intrinsic_alias`).
A reference `sin y` / `sin[y]` then lowers straight to `Apply1(Op1.sin)` at the call
site — no lambda frame — so it fuses with adjacent elementwise ops:

```
sin a            → Apply1 sin
sqrt 1.0+a       → FusedMap [Col0 Col1 Add0 Sqrt0]     (at the call site, and inside
                                                        user lambdas: {sqrt 1.0+x})
```

Shadowing is fully respected: a `::` double-bind (variable) or any non-wrapper rebind
of the name clears the alias, and a local/param of the same name (`{[sin] …}`,
`{sin: …}`) is skipped (`isLocalName`). Verified via `ink disasm` + unit tests
(`{[sin] sin 5}[{x*10}]` → 50; `sin: {x+100}` → user def wins). This is the
monomorphic call-site optimization the whole reorg was aiming at.

**General `:`-constant propagation (DONE).** The alias generalises: a global bound at
global scope with a single colon (`:` = constant) to a **pure literal** (scalar /
vector / string / symbol) is recorded `name → rhs` in `Compiler.const_globals`; a
reference then re-emits the literal inline (`compileVar`), so the `Global` load is
elided and downstream arithmetic constant-folds and const scalars bake into fused
kernels:

```
n: 100;  2*n          → Const 200
dt: 0.5; {x+dt}[10]   → dt inlined; 10.5
pi: 3.14159; {pi*x*x} → λ body: Const 3.14159 + FusedMap [Col0 Col1 Col2 Mul0 Mul0]
```

Soundness does **not** assume the contract is followed: real code writes
`a:1; {a::2}[]; a` (mutating a `:`-global via `::` inside a lambda). A per-unit
prescan (`collectMutated`) walks the whole tree — into lambda bodies and every
node that can hold a bind — and records every name assigned by `::`, a compound op
(`+:`), an indexed lvalue (`d[i]:…`), or a destructure-compound (`(a;b)*:…`). Any
such name is excluded from `const_globals`/`intrinsic_alias`, so a mutated name is
never folded. `const_globals` values are ast nodes owned by the current unit's
tree, so the map is per-unit (cleared each top-level `compile()`); cross-unit
propagation (a lib constant into another file) is not done. Verified via the
existing global/list-assign tests plus new folding tests.

**Neutral IR seam — the Tiramisu layer (DONE for the fragment-expression path).**
Instead of `compNode` welding CST→SPIR-V, `dye.k` now grows a target-neutral, typed
SSA IR and a two-stage pipeline. IR node = an index into parallel lists
`xOp / xTy / xArg / xVal` (op sym, result type, operand node indices, literal/glyph):

```
{[uv] (uv[0]; uv[1]; 0.5; 1.0)}  →
  0: param   :v2  ()          22       (the loaded input id)
  1: extract :f32 (0)         0
  2: extract :f32 (0)         1
  3: const   :f32 ()          0.5
  4: const   :f32 ()          1.0
  5: cons    :v4  (1,2,3,4)
```

- **Builder** `xNode` (mirrors `compNode`) walks the CST into IR, returning
  `(nodeIdx; ty)` instead of emitting.
- **Optimizations** run once on the neutral IR: `xFold` (const-folds f32 scalar
  arith + a few unary math, executed on the host since dye is the CPU compiler),
  `xReach` (DCE — a guarded reachability fold).
- **Two back-ends over the same IR**: `xLowerSpirv` (assigns ids, replays the `op*`
  stencils — copy-and-patch's stencil library) and `xDump` (textual). A third
  (ink-VM bytecode / copy-and-patch CPU) is now just another lowering.
- `FragmentShaderIr` drives a fragment lambda through build→fold→DCE→lower.

Verified (`test/ir.k`): **byte-identical** to the direct `FragmentShader` when
nothing folds (record-then-replay: ids are assigned in lowering order = IR order),
`x+1.0+2.0` folds `1.0+2.0→3.0` (shorter module), and a real circle SDF compiled
*through the IR* renders on the GPU. Golden + unit tests + direct demos unchanged.

Scope: the fragment-expression subset (arith, math, vector cons/extract, select,
comparisons, broadcast, local binds). The compute/vertex entry points still use the
direct `compNode` — their in-kernel loop phis, atomics, and scatter don't fit a pure
value-SSA IR; migrating the default path onto the seam is the follow-up.

**Remaining Phase 3 (larger, deferred):**
- Migrate the default `FragmentShader`/vertex/compute onto the IR (needs IR ops for
  stores/loads/atomics/loop-CFG), plus CSE and a shared `assembleCompute`.
- *Two VM bugs* (see `doc/bug.md`): the nested-`2:` load underflow (fixing it lets
  `dye.k` self-load `spirv.k`) and the `@`(symbol, int-scalar) mis-dispatch.

### Phase 4 — namespace the GPU library
Rename the capital-letter globals into namespaces (blast radius: 3 defining libs,
4 consumer libs, ~33 demos, `doc/reference.md`). Proposed map:

```
window.run                                   (already namespaced)
gpu.fill gpu.tessellate gpu.drawShader gpu.solid gpu.runShader
gpu.buffer gpu.read gpu.write gpu.dispatch gpu.compileCompute gpu.compileSpirV
mesh.compile mesh.draw{,U,T} mesh.upload mesh.drawGeomT mesh.drawInstanced{,T}
shader.fragment{,Tex,TexN} shader.vertex{,U} shader.instancedVertex
shader.compute{,2} shader.stencil{,U,IP} shader.scatter shader.kernel
texture.upload
spirv.*    (the op* stencils + ids; already private, zero external callers)
bits.*     (future: dye → ink-VM bytecode back-end)
```
Open naming calls: `gpu.*` vs `mesh.*` for the immediate-mode trio
(`FillFrame`/`DrawShader`/`tessellate`); `shader.kernel` vs `gpu.kernel` for
`GpKernel`; keep `gpu.runShader` (not `gpu.run`, which clashes with `window.run`).
Migrate with one commit of thin aliases, update consumers, then drop the aliases.

# Tasks

## kk next increments → see .plan/kk-next.md
Detailed per-task briefs (context, files, gotchas, acceptance oracles) for a
fresh session: bits v1 (IR→FusedMap CPU backend, generated nn references),
fragmentIr fold-in, interleaved placed tables + placed dicts (CSR) + the cloth
edge kernel on named columns, earth.k on vertex pulling (+textures/uniforms
for pull pipelines), tier-2 group/histogram then radix sort, `n f/ d`
dispatch recording + kernel compile-on-apply, and small chores (snap.sh glob).
Status recap: placed tables landed 2026-07-16 (elementwise slice, planar
layout, dead-column pruning, `9: table`/`8:` reassembly); the deferred parts
(interleaved layout, ragged dicts, tables composed with gather/scatter) are
kk-next.md Task 3.

## Rework library and namespaces
I want to change to way the module system works with auto-loading,
namespaces, variable resolution and fully qualified names.
From now on every k file in `./lib` should declared it's own namespace with the same name as the file. So image.k becomes the namespace image.
There should be one exception for the `./lib/_.k` file it should be added to the global namespace.
Other k files loaded with `\l filename.k` should also be in a namespace `filename`.
This means the ./src/cmd/module.zig and others should change.
Make sure the bundeling keeps working. The ./tools/zed-ink extension should also update.
The lsp should also be changed to it resolved the right variables.
There is the issue of public and private variable, add a extra command to do this.
Add the `\public var1 var2` command but also keep the other syntax.
Update existing libraries in `./lib`
The public command also needs support in the zig parser and tree-sitter parser.

## Improve tooling
Fix the following in the zed-ink extension and tree-sitter-ink parser.

## Resolve group vs freq

## Early returns
Implement early returns in a lambda using `:` (like the ngn/k).

## Ink Agent Skills
Help me write skills for developing ink code based on this codebase.
Add skills for the following task profiles.
- Ink development agent: skills, tools, ebnf, idioms, code style
  - parse tool
  - bytecode tool
  - snapshot tool
- Ink native module development

## Doc tool `ink doc`

## Remove `.blank` type

## Runtime error locations
Parse errors carry `line:col` + a caret as of 2026-07-30 (compile-time only, no VM
cost). RUNTIME errors still don't: `!type` tells you nothing about where.

The blocker is that ink returns errors as VALUES, so there is no single raise point to
hook — the error is minted deep in a primitive and flows back through the dispatch
loop like any other value. Measured: adding `if (r == .err) vm.err_pc = …` to
`doApply` costs **+3.7% (dot), +7.7% (fibonacci)** in ReleaseFast. Rejected on the
"don't make the VM slower" rule; the prototype was reverted.

Options that avoid the hot path:
- **A comptime flag** (`-Ddebug-locs`) that compiles the hook in only for debug
  builds. Zero cost in release, locations when you're actually debugging. Probably the
  answer, and cheap — the prototype is 2 lines plus a `pc → span` side table per chunk
  (sorted, binary-searched only when an error is formatted, so nothing on the happy
  path even when enabled).
- Re-run a failing statement with tracing on. Deterministic only for pure code, so it
  lies exactly where it would help most. Not recommended.
Whatever lands must not widen `V` — errors are minted constantly in dispatch.

## Diagnostics for silent blanks (DX)
The costliest debugging in the ASR/perf session was never a wrong result — it was a
blank flowing on quietly. Two ways to produce one, both silent:
1. **A nested lambda reads an enclosing lambda's local.** Lambdas don't capture, so
   `go:{[] p: …; {[i] gpu.dispatch[p; …]}' !n}` sees `p` as blank; handed to an FFI
   call it becomes a null handle that no-ops. A whole GPU benchmark "ran" for an hour
   while dispatching nothing.
2. **GPU resources built outside `gpu.computeRun`.** No device exists yet, so
   `gpu.buffer` returns handle `0` and every later dispatch silently does nothing.

Two fixes were built and BACKED OUT (2026-07-29), so don't re-derive them:
- **Compile-time error** when a name resolves to an enclosing lambda's param/local:
  100% false positives across lib/. GPU kernel and shader bodies (`gpu.kernel`,
  `shader.*`) are ordinary lambdas to this compiler but are INLINED by dye, where
  enclosing locals are legitimately in scope (`gemmK` in lib/nn.k, the slug fragment
  shader). lib/fbx.k also mirrors a param into a same-named global on purpose
  (`target::target`). The compiler cannot tell host lambdas from shader lambdas.
- **A `GlobalCk` opcode** that read the global and raised only when it was actually
  blank. Precise (shaders never execute it, the mirror idiom resolves normally) and
  free (ordinary `.Global` untouched, benchmarks unchanged) — but too specific a
  mechanism to carry in the opcode set, and it leans on `.blank`, which is going away.

So this wants a general answer, not another special case. Ideas, once `.blank` is
replaced by monadic `::`:
- Make "identity/right applied to nothing" visibly distinct at the point of USE rather
  than at the point of read — e.g. FFI marshalling rejects it instead of coercing to a
  null handle, which fixes cause 2 as well.
- A `--strict`/debug build mode that reports blank reads, off in normal runs, so
  shader compilation and the mirror idiom are unaffected.
- Whatever lands should keep the shader-inlining case working and cost the VM nothing.

## Paralle each adverb
Maybe we can use the digram form of the each adverb for parallel each.
There is already stencil and window, we can add `` `ncpu f'!1000 `` to mean
that the function f should be applied to `!1000` distributed over number of cpu cores.

## GPU: Dawn → Vulkan (MoltenVK) migration — DONE (cut over 2026-07-14)
Full design + phase log: `doc/design/vulkan-migration.md`. Vulkan/MoltenVK is now
the ONLY backend (no `-Dgpu-backend` flag; Dawn/zgpu/zdawn/zpool + the lazy
`dawn_aarch64_macos` dep + `patches/` + `blit.wgsl`/`fill.wgsl` all deleted).
`build.zig` links `libMoltenVK.a` + vulkan-headers + GLFW and merges them into one
archive for the static bundle. `gpuWgsl` removed. **Phase 6 done unconditionally**:
`lib/dye.k` emits SPIR-V **1.4 natively** (version word `0x00010400` + full-interface
`OpEntryPoint`) at every assembler; `vk.maybeBump`/`INK_SPV14` are gone. The k-facing
FFI (30 `gpu*` exports) is unchanged, so `lib/gpu.k` + all `test/*.k` still work.
Toolchain: `brew install molten-vk vulkan-headers`. **glslang is NO LONGER a build
dependency** — `fill.vert.spv`/`fill.frag.spv` are committed blobs `@embedFile`'d by
`lib/gpu/vk.zig`; nothing regenerates them at build time.

### Remaining graphics work (in rough priority order)
1. **Retire the native tessellation path — DONE (2026-07-25).** Deleted `lib/gpu/fill.frag`
   + `fill.frag.spv` + `lib/gpu/triangulate.zig` + the `gpuFill`/`gpuTess` exports +
   registrations + the `gpu.fill`/`gpu.tessellate` bindings + the built-in fill fragment
   module/pipeline (`fill_fmod`/`fill_pipe`) and its `drawFill` fallback in `vk.zig` +
   the `triangulate` build module. Migrated the last three interactive demos to
   `lib/canvas.k`: `demo/{asr,edit,replay}.k` (analytic shapes via cnv.rect/cnv.ellipse,
   transcript/editor text via cnv.text — the whole per-glyph tessellation cache is gone).
   `fill.vert`/`fill.vert.spv` KEPT — `gpu.drawShader` (demo/{demo,drawing,drive,pbr,sdf}.k,
   test/ir.k) + the Slug 2-D backend pair it with a dye-compiled fragment via
   `createFillShaderPipe`. Verified: gpu builds clean, all 5 render demos + circle snapshot,
   `make ui-test` 31/31, `make ui-shot` 3/3 golden. The active 2D renderer (`lib/slug.k`
   FRAGF) was already self-hosted in dye, so nothing needed self-hosting — the NanoVG
   bridge was just deleted.
2. **Self-host `fill.vert`** (optional, low value) — the one remaining GLSL blob. Needs a
   vertex-attribute path in dye (it only *pulls* from storage buffers by `gl_VertexIndex`
   today; `fill.vert` takes `in vec2 pos/uv` + a viewSize UBO). Tiny, stable shader — the
   committed `.spv` is fine to keep, so this is only worth it to reach literally-zero
   non-dye shader source.
3. **Instancing API — RESOLVED (won't-do, 2026-07-25).** The old
   `gpuDrawInstanced`/`gpuDrawGeomResident`/`gpuDrawInstancedT`/`gpuDrawMeshT` exports were
   never ported to the Vulkan backend (no exports, no bindings, no `lib/instancing.k`), so
   there was nothing to delete — only stale doc references (now corrected). Vertex pulling
   (`shader.vertexPull`/`mesh.drawPull`, see `demo/scene.k`) renders N entities in one draw
   with no vertex-input state and subsumes the use case. Not reviving it.
4. **Shader-dialect I/O gaps** (see `.plan/triage.md` GPU section): i32/bool as shader
   I/O types; multiple fragment outputs (MRT); user-facing int/float cast syntax; real
   `OpBranchConditional` for side-effect-guarding expressions.
5. **`dFdx`/`fwidth` AA** — a real `OpDPdx`/`OpDPdy`/`OpFwidth` intrinsic in dye for exact
   edge AA under any transform (AA width is host-computed ~1.2px today).
6. **Cross-platform**: the Vulkan backend is macOS/arm64-only for now; the `vk.zig`
   surface/extension seam was written to admit Linux/Windows later — wire those up.
7. **Multi-time `-snap` scheduling** (single-frame capture works; port the old
   scheduler that shoots at several sim-times).
8. **Perf pass**: compute is correctness-first (deferred submission, `vkQueueWaitIdle`
   at each readback). Revisit with fences / overlap if profiling shows it matters.

## Canvas / Slug 2D renderer
Full roadmap + architecture + gotchas: **`doc/design/canvas-slug.md`** (read §3 first).
The 2D stack is now ONE analytic backend — fills, gradients, clips, strokes, text, and
image paint all render through the Slug scene buffer (`lib/slug.k` + `lib/canvas.k`); no
tessellation. DONE this cycle: gradients/clip in the fill shader, strokes as miter
outlines, one-backend cutover, image paint (`shader.fragmentBufTex`), CFF/OTF `font.quads`
(cubic→2 quads), scene-buffer compaction (indexed band layout), and scene/quad-pool
double-buffering. Also DONE 2026-07-21: `&`/`|` polysemic in the shader dialect (task 3),
text clipping (task 4), image sampler confirmed LINEAR (task 6).

**OKLab gradient interpolation — DONE 2026-07-23.** Gradients now interpolate in OKLab
(perceptually uniform; no muddy sRGB-lerp midpoint) instead of per-channel gamma sRGB. All
in the dye-compiled FRAGF fragment (`lib/slug.k` ~L311-345) using existing dialect intrinsics
(`pow`/`step`/`mix`/`|`-max) — same Ottosson matrices as `lib/color.k`'s `oklch`. SOLIDS stay
BIT-EXACT: `sel: step[0.5;extx]` picks the untouched inner sRGB for solid paints (extx<0.5), so
the OKLab round-trip never perturbs solid fills or glyphs → all UI logic + golden-pixel tests
still pass (`test/ui.k` 26/26, `test/uishot.k` 3/3). Verified on `demo/canvas.k`: 24.9k px changed
(exactly the two gradient regions), every sampled solid/text/stroke pixel identical. Cost: the
eager-select computes OKLab for every fill pixel (no expression-branch in the dialect), but it's
dwarfed by the existing per-pixel analytic-coverage band loop. Needed the CPU `cbrt` operator
(`syms.zig`+prelude) for the palette path; the shader uses `pow[·;1/3]`. Remaining, rough priority:

1. **Band-loop truncation cap — DONE 2026-07-21.** The scene-buffer fragment now loops the
   REAL per-band count via `rsum[bcnt; …]` (a RUNTIME trip count — `loopOpen` already
   compares the i32 counter against a runtime `Kmax`, so no `whileL` and no dye change were
   needed, only slug.k). Removed the host-side `(#sel)&slugMPB` cap in `oneBandC` (compacted
   path stores every overlapping curve; `oneBand`/texture path keeps its cap since its texture
   width is fixed) and dropped the clamp+`valid` mask in FRAGF/FRAGFI. Verified with an
   18-stripe single-fill test (36 curves/band): all render; re-adding the cap drops the dense
   middle stripes (winding leak reproduced then fixed).
2. **`dFdx`/`fwidth` AA.** AA width is host-computed per fill/glyph (~1.2px). A real
   `OpDPdx`/`OpDPdy`/`OpFwidth` (207/208/210) intrinsic in dye makes edge AA exact under
   any transform. Needs the `DerivativeControl`/no-cap fragment path.
3. **`&`/`|` → min/max in the shader dialect — DONE 2026-07-21.** `dispBin`/`binRty`/
   `xTransNorm` in `lib/dye.k` now dispatch `&`/`|` by operand type: bool→`OpLogicalAnd`/
   `Or`, float/vector→`OpFMin`/`OpFMax`. slug.k's shader bodies use `&`/`|` (dropped the
   `min[]`/`max[]` workaround); verified canvas + slug demos render unchanged. 6 golden
   assertions added to `test/spirv.k` (float→FMin/FMax, bool→logical).
4. **Text clipping — DONE 2026-07-21.** `slugText` snapshots the live clip (`TXCLM`/`TXCLE`)
   per glyph; `txPaint` bakes it via `applyClipM`. Verified: text cropped to a clip band.
5. **Retire the native tessellation files** (`triangulate.zig`, `fill.frag`) — IN PROGRESS.
   - `gpu.fill`/`gpu.tessellate` DEPRECATED 2026-07-21 (marked in `lib/gpu.k`); use canvas.
   - Migrated to canvas: `demo/{eyes,drawing,typeset}.k` (verified via `-snap`). Added
     `cnv.rect`/`cnv.ellipse`/`cnv.circle` convenience path builders to `lib/canvas.k`.
   - STILL on the deprecated API: `demo/{replay,edit,asr}.k` — interactive apps (audio
     waveform = vertical bars, ASR viz, a text editor with a glyph-tessellation cache +
     event table). Pure `gpu.fill`/`gpu.tessellate` (no mesh/shader draws → they CAN move to
     canvas), but each needs restructuring (side-effecting rect/text fills, waveform as a
     path, glyph cache → `cnv.text`) and interactive validation, so deferred.
   - NOTE: `fill.vert` CANNOT be deleted — `gpu.drawShader` (circle/pbr/drive/demo/ir, NOT
     deprecated) draws its custom fragment over the built-in fill VERTEX shader. Only
     `fill.frag` + `triangulate.zig` + `gpuFill`/`gpuTess` can go, and only after the 3 apps
     migrate. Also the Phase-7 self-host task above.
6. **Image sampler filtering — DONE (already LINEAR).** `texture.upload` (vk.zig
   `createTexture`, line 635) is `VK_FILTER_LINEAR`, so image paint already scales smoothly;
   only the data texture (`createTextureF`) is NEAREST (required for exact per-texel reads).

### Shader dialect
- **`&`/`|` as min/max in shaders — DONE 2026-07-21.** The dye dialect now dispatches
  `&`/`|` by operand type: `OpFMin`/`OpFMax` for float/vector operands, `OpLogicalAnd`/
  `Or` for bool — so `y0&y2` in a shader is `min[y0;y2]`, matching ordinary ink. Touched
  `dispBin` (route by `aty~bool`), `binRty`/`cmpOps` (result type propagates for numeric
  `&`/`|`), and `xTransNorm` (drop the forced-bool operand hint). slug.k dropped its
  `min[]`/`max[]` workaround. Golden coverage in `test/spirv.k` §9.

### Housekeeping
- `spike/` (vkspike.zig + run.sh) is the throwaway Phase-0 proof — keep or delete.
- `test/computevk.k` is the headless Vulkan compute smoke test — keep.
- The 8 ported compute tests now use `gpu.computeRun` (run on both backends).

## UI framework (7GUIs) — lib/ui.k + lib/fmt.k
All seven 7GUIs built & verified (demo/{counter,temperature,flight,timer,crud,circle,cells}.k).
Full design + API reference + roadmap + test-framework plan in **doc/design/ui.md**.
UI TEST FRAMEWORK (2026-07-22): headless harness `lib/uitest.k` (`t.*` event-replay over the real
`props`events`→ui.run→ui.frame path) + `test/ui.k` (26 assertions: layout/hit-test/action-dispatch/
focus + full interaction: text editing/backspace/arrows/home/end, slider drag, select open+pick,
list select) + `make ui-test`. All interaction state commits headlessly — the "VM COW bug" chased
earlier was a TEST-CODE parsing gotcha (`"…",get`k,"…"` = `get@(`k,"…")`; `step ,ev` = `step , ev`),
not a runtime bug. PIXEL PATH DONE: native `window.test[fn;(w;h)]` (gpuRenderRun, hidden-window
swapchain, shots exactly w×h) + `gpu.shot[path]` (gpuShot) in lib/gpu/gpu_vk.zig; harness
`t.render`/`t.shot`/`t.shotEq[name;tol]` (golden-diff via image.read, baseline-on-first-run, lazy
font load); `test/uishot.k` + `make ui-shot` + test/golden/*.png. Constraint: ONE window.test per
process (canvas/dye cache device pipeline handles in k globals → 2nd context blank); goldens are
GPU-specific. FOLLOW-UP: k-level pipeline-cache invalidation on device teardown (enables multi-context).
Ranked remaining work: k-level cache-invalidation → gotcha-lint → scrolling → floating-overlay →
multi-context → perf → polish (alignment/theming/proportional-fonts/error-surfacing) → richer Cells
formulas. Likely compiler bug logged above: namespace member written only externally is invisible to
inside readers when file-loaded.

## larger Graphics Tasks
- ~~**Retire native tessellation**~~ — DONE 2026-07-25 (see GPU migration §above): all 2D is
  analytic through lib/canvas.k; triangulate.zig / fill.frag / gpuFill / gpuTess deleted.
- **OKLab colormaps for dataviz** — generate perceptually-uniform colormap textures (the `texType 3` path) CPU-side; pairs naturally with the OKLab work.
- **Self-host `fill.vert`** — the last GLSL blob; needs a vertex-attribute path in dye. Low value (build no longer depends on glslang; it's a committed `.spv`).

## rework the namespace module system.

I want to only use fully qualified names when declaring and using identifiers.
We currently use the `\d` declare command together with a lookup strategy where we match a identifier with the local namespace before looking for that name in the global namespace.

This is confusing the follow, makes tooling lsp hard and is brittle because some local namespace can shadow the global namespace, The namespace is also nothing more then a naming convention for identifiers using a dot in their name.

So I want to just use the fully qualified names in the library and examples. [@lib](file:///Users/werner/Code/ink/lib/) [@demo](file:///Users/werner/Code/ink/demo/) 

Remove the module logic from the VM but keep the autoloading (it should be easier) and update all the library code. The autoloading should keep working.

this should also get rit of the visibility rules for namespaces.

Try to keep the namespace clean by putting helper functions that are only used inside of a lambda in that namespace

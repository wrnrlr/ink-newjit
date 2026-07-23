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

## New operators for colors: cube-root `cbrt`

## Paralle each adverb
Maybe we can use the digram form of the each adverb for parallel each.
There is already stencil and window, we can add `` `ncpu f'!1000 `` to mean
that the function f should be applied to `!1000` distributed over number of cpu cores.

## GPU: Dawn → Vulkan (MoltenVK) migration — IN PROGRESS
Full design + phase log: `doc/design/vulkan-migration.md`. Why: WebGPU/Dawn's Tint
SPIR-V reader is permanently capped at Vulkan 1.1 / SPIR-V 1.3, so it refuses the
SPIR-V 1.4 that `lib/dye.k` can emit. MoltenVK ingests SPIR-V 1.4 natively. The
k-facing FFI (30 `gpu*` exports) is frozen, so `lib/gpu.k` + all `test/*.k` are
unchanged; backend chosen with `-Dgpu-backend=vulkan` (default still `dawn`).
Toolchain: `brew install molten-vk vulkan-headers glslang`.

**DONE + verified (pixel/numerically identical to Dawn):**
- Phase 0 spike, Phase 1 build plumbing, Phase 2 **compute backend** — full ASR/nn
  stack (nn/conformer/weights/gpusolve/stencil/relax/subsample/frontend) headless.
- Phase 3 render increments 1 (window/swapchain/present/events), 2 (basic mesh),
  2b (uniform mesh), 3 (2D fill + custom SDF fragment), 2c (textures + retained
  geometry). 11 render tests pixel-identical: sphere/pbr/sword/eyes/circle/planes/
  drawing/typeset/demo/edit/earth. Snapshot path: `INK_SNAP=frame`→`<base>-snap.png`.
- **Phase 6 SPIR-V 1.4 — achieved live**: `vk.maybeBump` (`INK_SPV14=1`) rewrites
  compute modules to 1.4 (version word + `OpEntryPoint` iface expansion); whole
  compute/nn stack runs on genuine 1.4 via MoltenVK, bit-identical to 1.3.

### Follow-up tasks (remaining, in rough priority order)
1. **Instancing** (`gpuDrawInstanced`/`gpuDrawGeomResident`/`gpuDrawInstancedT`,
   `gpuDrawMeshT`) — instance storage buffer @group(0). NOTE: current test targets
   `scene`/`clothpull` render all-black even on Dawn in headless `-snap`, so they're
   not snapshot-verifiable as-is; add a verifiable instancing test (or drive them
   enough frames to have on-screen geometry) before/while implementing.
2. **Phase 5 cutover**: make `vulkan` the default backend; delete Dawn/zgpu/zdawn/
   zpool + the lazy `dawn_aarch64_macos` dep + `patches/`; rework `ink bundle`/`make
   static` to link MoltenVK; **remove `gpuWgsl`** (still a stub) and delete
   `blit.wgsl`. Update `AGENT.md`/`CLAUDE.md`.
3. **Phase 6 make unconditional**: after cutover, fold `vk.maybeBump` into `lib/dye.k`
   (emit 1.4 directly: version word `0x00010400` + per-emitter `OpEntryPoint` iface
   expansion) and drop the `INK_SPV14` flag + `maybeBump`. Re-baseline `test/spirv.k`
   golden (version word + word counts change).
4. **Phase 7 self-host `fill`**: re-author `lib/gpu/fill.vert`/`.frag` (currently GLSL
   → `.spv` via `glslangValidator`) in the ink shader dialect compiled by `dye.k`;
   delete the GLSL sources + `.spv` + the glslang dependency. End state: zero
   `.wgsl`/`.glsl`, no external shader compiler.
   **SCOPE (assessed 2026-07-23):** this is a real dye-compiler project, not a mechanical
   port — 5 of 7 features `fill.frag` uses don't exist in the dialect: (a) **no fragment
   uniform block** (only compute has UBOs; the `frag[11]` vec4 array is the shader's whole
   parameterization) — needs a new `shader.fragment*` variant emitting a Uniform struct at
   set0/b1 with `loadUniMember`-style indexed access; (b) **no matrix type** (mat3×vec3 must
   be hand-expanded to scalar dot-products, as slug.k already does); (c) **descriptor-layout
   mismatch** — dye emits images at set1 with ONE shared sampler, `fill.frag` needs set0,
   per-texture samplers, interleaved bindings 2-5; (d) **no vertex-attribute path** — dye
   only *pulls* from storage buffers by `gl_VertexIndex`, so `fill.vert`'s `in vec2 pos/uv`
   + viewSize UBO have no equivalent (plumbing keeps the embedded `fill.vert.spv` so the
   vertex stage can stay GLSL-bridged); (e) **no multi-component swizzles** (`.xy`/`.zw`/
   `.rgb` are everywhere; only single-component `v[i]` extract exists) — needs OpVectorShuffle
   or every swizzle rewritten as a component list. The 5-way `type==0..4` dispatch itself is
   fine (eager nested `OpSelect`, composite-legal on the 1.4 header — just samples all
   textures). Wiring (`vk.zig:608` `@embedFile`) also means re-sourcing the SPIR-V: either a
   build step that runs `ink` to emit `fill.frag.spv`, or moving fill-pipeline creation to the
   runtime k-driven `gpu.drawShader`/`buildFillPipe` path (which today reuses the fixed
   6-binding set0 layout dye can't emit). Do (a),(b),(e) first — they touch nearly every line.
   **NOTE — NOT a prerequisite for OKLab.** OKLab gradient interpolation was the motivation,
   but the ACTIVE 2D renderer (`lib/slug.k` FRAGF) is ALREADY self-hosted in dye, so OKLab
   landed there directly (2026-07-23, see Canvas/Slug §below) with no Phase 7. `fill.frag` is
   the legacy NanoVG bridge (deprecated `gpu.fill`/`gpu.tessellate` path); Phase 7 is only
   about deleting the glslang dependency, and can proceed on its own timeline.
5. **Cross-platform**: the Vulkan backend is macOS/arm64-only for now; the `vk.zig`
   surface/extension seam was written to admit Linux/Windows later — wire those up.
6. **Multi-time `-snap` scheduling** (single-frame capture works; port the Dawn
   scheduler that shoots at several sim-times).
7. **Perf pass**: compute is correctness-first (deferred submission, `vkQueueWaitIdle`
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
- **OKLab colormaps for dataviz** — generate perceptually-uniform colormap textures (the `texType 3` path) CPU-side; pairs naturally with the OKLab work.
- **Phase 5 Vulkan cutover** — make `vulkan` the default backend, delete Dawn/zgpu. Big cleanup, unblocks Phase 6/7.
- **Phase 7 fill self-host** — now scoped (the 5 dye-compiler gaps are documented); a deliberate multi-step effort to drop the glslang dependency.
- **Retire native tessellation** — migrate `demo/{replay,edit,asr}.k` off `gpu.fill`/`gpu.tessellate` to canvas, then delete `triangulate.zig` + `fill.frag`.

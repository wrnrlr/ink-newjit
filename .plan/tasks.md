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
5. **Cross-platform**: the Vulkan backend is macOS/arm64-only for now; the `vk.zig`
   surface/extension seam was written to admit Linux/Windows later — wire those up.
6. **Multi-time `-snap` scheduling** (single-frame capture works; port the Dawn
   scheduler that shoots at several sim-times).
7. **Perf pass**: compute is correctness-first (deferred submission, `vkQueueWaitIdle`
   at each readback). Revisit with fences / overlap if profiling shows it matters.

### Shader dialect
- **`&`/`|` as min/max in shaders**: in the dye shader dialect `&`/`|` currently emit
  only `OpLogicalAnd`/`OpLogicalOr` (bool), whereas in ordinary ink they are polysemic
  (min/max on numbers, and/or on bools). This surprises shader authors — `y0&y2` for
  `min[y0;y2]` silently compiles to a logical-and of two floats (see lib/slug.k, which
  had to use `min[]`/`max[]`). Make the dialect dispatch `&`/`|` by operand type: min/max
  (`OpFMin`/`OpFMax`) for float/vector operands, logical for bool. Lower risk than it
  looks — the `min`/`max` builtins already exist (xMathW `opFmin`/`opFmax`); this just
  routes the `&`/`|` glyphs there when the operands aren't bool. Add a shader test.

### Housekeeping
- `spike/` (vkspike.zig + run.sh) is the throwaway Phase-0 proof — keep or delete.
- `test/computevk.k` is the headless Vulkan compute smoke test — keep.
- The 8 ported compute tests now use `gpu.computeRun` (run on both backends).

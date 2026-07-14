# GPU backend migration: Dawn/WebGPU → Vulkan (MoltenVK)

Status: **DONE — cut over 2026-07-14.** Phase 5 (Dawn/zgpu/zpool/`gpuWgsl`/
`blit.wgsl`/`fill.wgsl` deleted, vulkan is the only backend, static bundle
merges gpu+MoltenVK+GLFW) and Phase 6 (dye.k emits SPIR-V **1.4 natively** —
version word + full-interface `OpEntryPoint` in all four assemblers: `kAsm`,
`buildMod`, `shader.vertexU`, `lib/instancing.k`; `maybeBump`/`INK_SPV14`
removed) landed together after the kk emitter consolidation left one `hdr:`
site per assembler. Verified: `test/spirv.k` golden (version chks now 1.4),
12/12 kkgold modules `spirv-val --target-env vulkan1.2` clean, walk3/nn
numerics unchanged, sphere/circle/eyes/earth/clothgpu render stats identical.
Remaining from the old list: instancing exports are still stubs (subsumed by
vertex pulling — doc/design/kk.md §4/§5.7); Phase 7 (self-host fill.k) open.

Original document below. Author's note: written after establishing that Dawn's Tint
SPIR-V *reader* is permanently capped at Vulkan 1.1 / SPIR-V 1.3 (see
`.plan/triage.md` "SPIR-V 1.4 upgrade"). The only way to actually run SPIR-V 1.4+
is a runtime that ingests SPIR-V natively. This document plans that swap.

## 1. Objective & non-goals

**Objective.** Replace the Dawn/WebGPU host backend with a raw **Vulkan 1.2+**
backend (via **MoltenVK** on macOS) so the SPIR-V that `lib/dye.k` emits is handed
straight to `vkCreateShaderModule` — no Tint reader, no WGSL detour, full SPIR-V
version range. Then flip `dye.k`'s version word to `0x00010400` to deliver 1.4.

**Hard invariant — the k-facing ABI does not change.** All 30 `gpu*` FFI exports
(and their `k_register` names) keep identical signatures and semantics, so
`lib/gpu.k`, `lib/dye.k`, `lib/spirv.k`, `lib/mesh`/`camera`/`pbr`/`nn` and every
`test/*.k` keep working **untouched**. This is what bounds the project: it is a
re-implementation of one Zig host layer behind a frozen interface, not a redesign.

**Stays unchanged:**
- `lib/dye.k`, `lib/spirv.k` — the SPIR-V compiler (the whole point of the move).
- `lib/gpu/triangulate.zig` — CPU tessellation, no GPU calls.
- `lib/gpu/png.zig` — snapshot PNG encoder (consumes a CPU pixel buffer).
- The k namespace API in `lib/gpu.k` (`window.run`, `gpu.*`, `mesh.*`, …).

**Non-goals (v1).** Keep GPU **macOS/arm64-only**, exactly as today
(`build.zig` gates the whole section). Vulkan is cross-platform, so this migration
*unlocks* Linux/Windows GPU later — but shipping those is out of scope for v1.
Also out of scope: any change to the 2D raster feature set, mesh formats, or the
compute kernel dialect.

## 2. Why this is the right runtime

`lib/dye.k` is a SPIR-V compiler. WebGPU is the one modern GPU API that **cannot**
take SPIR-V as a first-class input — Dawn only accepts it through a non-standard,
deliberately-restricted `ShaderModuleSPIRVDescriptor` side door pinned to the
Vulkan 1.1 validation env. Vulkan *is* the SPIR-V-native API; MoltenVK (SPIRV-Cross
→ MSL under the hood) already ships SPIR-V 1.4 support with Vulkan 1.2 and up. So
this is not a lateral move — it aligns the runtime with what the compiler emits.

## 3. The frozen FFI contract (what must keep working)

30 exports in `lib/gpu/gpu.zig`, grouped by subsystem. The Vulkan port
re-implements each; the k signature is fixed.

**Compute / buffers (window-less — Phase 2):**
`gpuBufferNew` `gpuUniformNew` `gpuBufferWrite` `gpuBufferRead` `gpuBufferReadI`
`gpuComputeNew` `gpuComputeNewU` `gpuDispatch` `gpuDispatchLoop` `gpuComputeRun`
`gpuCompute` `gpuCompute2` `gpuSpirv`(compute pipelines share the module path)

**Windowed render (Phase 3):**
`gpuRun` (event loop + swapchain + present) `gpuFill` `gpuTess` `gpuFillShader`
`gpuSpirv` (raster frag pipeline) `gpuWgsl` (⚠ see §6) `gpuMesh` `gpuUploadMesh`
`gpuDrawMesh` `gpuDrawMeshU` `gpuDrawMeshT` `gpuDrawInstanced` `gpuDrawInstancedT`
`gpuDrawGeomResident` `gpuDrawGeomT` `gpuTexture`

**Init:** `terse_init` / `ink_ext_init_gpu` (registry install — unchanged).

## 4. Concept mapping (WebGPU → Vulkan)

The current surface, from `grep`: `Device Queue Buffer BindGroup(Layout)(Entry)
RenderPipeline ComputePipeline CommandEncoder RenderPass(Encoder) Texture
TextureView Sampler Vertex{Attribute,BufferLayout} BlendState ColorTargetState
FragmentState DepthStencilState RenderPassColor/DepthStencilAttachment`, plus
`zgpu.GraphicsContext` (surface, swapchain, `present`, `submit`) and
`createWgslShaderModule`.

| WebGPU (today) | Vulkan (target) | Notes |
|---|---|---|
| `zgpu.GraphicsContext` | hand-rolled `Gpu` struct | instance+device+queue+swapchain+cmd pools |
| implicit memory | `VkDeviceMemory` / **VMA** | Vulkan is explicit; use VMA to avoid a hand allocator |
| `device.createBuffer` | `vkCreateBuffer`+bind memory | usage flags map 1:1 (storage/uniform/vertex/transfer) |
| `queue.writeBuffer` | staging buffer + `vkCmdCopyBuffer` | or persistently-mapped host-visible for uniforms |
| `buffer.mapAsync` (read) | staging + copy + **fence** + map | `gpuBufferRead*` readback |
| `createBindGroupLayout` | `VkDescriptorSetLayout` | entry kinds identical (storage/uniform/sampler/texture) |
| `createBindGroup` | `VkDescriptorPool`+`vkAllocateDescriptorSets`+`vkUpdateDescriptorSets` | need a pool sizing strategy |
| `createRenderPipeline` | `VkGraphicsPipelineCreateInfo` | vertex layout, blend, depth all explicit structs |
| `createComputePipeline` | `VkComputePipelineCreateInfo` | trivial vs render |
| `createShaderModule(SPIRV)` | `vkCreateShaderModule` | **direct SPIR-V, any version** — the payoff |
| `createShaderModule(WGSL)` | *n/a* | see §6 built-in shaders |
| `CommandEncoder`/`beginRenderPass` | `VkCommandBuffer`+`VkRenderPass`+`VkFramebuffer` | (or dynamic rendering, §7) |
| `beginComputePass`/`dispatchWorkgroups` | `vkCmdDispatch` + barriers | explicit `vkCmdPipelineBarrier` between passes |
| swapchain `present` | `VK_KHR_swapchain` + `vkQueuePresentKHR` | + acquire/submit semaphores, resize recreate |
| depth attachment | `VkImage` (D32) + view | lazily resized (as today) |
| `createTexture`/`writeTexture`/`createSampler` | `VkImage`/`vkCmdCopy…`/`VkSampler` | `gpuTexture` + mesh-T draws |
| GLFW surface | `glfwCreateWindowSurface` (→ `VK_EXT_metal_surface`) | GLFW must be built with Vulkan; hint `NO_API` |

**MoltenVK specifics that bite:** instance needs
`VK_KHR_portability_enumeration` + the `…_ENUMERATE_PORTABILITY_BIT` flag; device
must enable `VK_KHR_portability_subset`; request **apiVersion ≥ Vulkan 1.2** (the
gate for SPIR-V 1.4 ingestion). Validation layers are optional but strongly
recommended during the port (`VK_LAYER_KHRONOS_validation` via the LunarG SDK).

## 5. Build & dependency changes (`build.zig`, `build.zig.zon`)

Remove (at cutover, Phase 5): `dawn_aarch64_macos` lazy dep, `patches/zgpu`,
`patches/zpool`, the `zdawn` artifact, the `libtool` Dawn merge for
`libgpu-bundle.a`.

Add:
- **Vulkan bindings:** `vulkan-zig` (Snektron) — generates a typed Zig binding +
  dispatch tables from `vk.xml`. Avoids hand-declaring the C API (as `gpu.zig`
  currently hand-declares `ShaderModuleSPIRVDescriptor`).
- **MoltenVK:** link `libMoltenVK` (static `.a` from the LunarG macOS SDK or the
  Homebrew `molten-vk` cask), or load the Vulkan loader + MoltenVK ICD at runtime.
  Static link is simplest for `ink bundle`. Frameworks already linked (Metal,
  QuartzCore, Foundation, IOKit, IOSurface) largely carry over; MoltenVK also
  wants `Metal`, `IOSurface`, `CoreGraphics`, `AppKit`.
- **VMA** (optional but recommended): C++ single-header; compile one `.cpp` TU
  (same pattern as the old `dawn.cpp` adapter).
- **GLFW with Vulkan**: the existing Homebrew `glfw3` already exposes
  `glfwCreateWindowSurface`; just stop requesting a WebGPU/Metal-layer surface.

Keep the whole section gated on `macos and aarch64`. Keep a **`-Dgpu-backend=`**
option (`dawn` | `vulkan`) during migration so `main` stays green until Phase 5.

## 6. The built-in-shader problem (must solve before Phase 3)

Two WGSL shaders are `@embedFile`'d and compiled with `createWgslShaderModule`:
- `lib/gpu/fill.wgsl` (132 lines) — the whole 2D raster fill pipeline
  (`vs_main`/`fs_main`, SDF fills, gradients, `FragUniforms` = 11×vec4). Also the
  vertex stage reused by `gpuSpirv` raster frags and by `gpuFillShader`.
- `lib/gpu/blit.wgsl` (29 lines) — fullscreen-quad blit for `-snap`.

Vulkan can't ingest WGSL. **Decided direction: author these in k and compile via
`lib/dye.k`, eliminating every non-SPIR-V shader source and the whole
WGSL/GLSL build-time toolchain.** A temporary precompile bridge is acceptable to
unblock Phase 3, but the end state has *zero* `.wgsl`/`.glsl` in the tree.

**`blit.wgsl` disappears outright — no replacement shader.** Under Vulkan the
offscreen→swapchain step is fixed-function: `vkCmdBlitImage` (or
`vkCmdCopyImage`), and the `-snap` readback is `vkCmdCopyImageToBuffer` straight
to host-visible memory → `png.zig`. So the built-in-shader problem reduces to
**`fill.wgsl` only.**

Two tracks for `fill.wgsl`:
- **Track A — bridge (Phase 3):** port `fill.wgsl` → GLSL, precompile to SPIR-V at
  build time with `glslc`/`glslangValidator` (`b.addSystemCommand`, `@embedFile`
  the `.spv`). Self-contained, unblocks the render backend immediately. This adds
  a *build-time only* GLSL dependency — no runtime WGSL/GLSL, no Tint/naga.
- **Track B — self-host (Phase 7, the goal):** re-author the fill vertex+fragment
  in the ink shader dialect as `lib/gpu/fill.k`, compiled by `dye.k`. `dye.k`
  already has a fragment path (`shader.fragment`/`Tex`, `shader.vertex`), so the
  vertex stage and texture sampling are covered; the fragment's fill-type dispatch
  (solid / gradient / texture) + SDF math must be expressed in the dialect, which
  may need small `dye.k` extensions. When done, delete the GLSL bridge and the
  `glslc` build step. This is what removes the *last* non-SPIR-V shader.

**`gpuWgsl` (user-facing WGSL compile) is DROPPED.** No in-tree `test/*.k` calls
it, and its whole reason for existing (WGSL as an authoring path) contradicts the
SPIR-V-native direction. Remove the export and its `k_register`; if any k code
references `gpu.wgsl`, replace with the SPIR-V path (`dye.k` → `gpu.spirv`). Leave
a one-line deprecation note in `lib/gpu.k`.

## 7. Phased implementation

Each phase is independently testable. **Phase 0 is mandatory before committing.**

### Phase 0 — De-risk spike — ✅ DONE (2026-07-13), premise PROVEN
`spike/vkspike.zig` + `spike/run.sh` (reproducible). Standalone Zig compute
program, no ink integration. Ran dye.k's own `shader.compute[{[x] x*2}]` on
input `1..5` through MoltenVK at **both** SPIR-V 1.3 (today's output) and SPIR-V
**1.4** (version word `0x00010400` + `OpEntryPoint` interface expanded):

    device: Apple M1 Pro  Vulkan 1.2.334
      [SPIR-V 1.3 baseline]         out = 2 4 6 8 10   => PASS
      [SPIR-V 1.4 (iface-expanded)] out = 2 4 6 8 10   => PASS

**MoltenVK ingests dye.k's SPIR-V 1.4 and computes correctly.** The whole
migration premise is verified on real hardware; everything after this is bounded
engineering. Concrete facts the spike nailed down (feed them into later phases):
- **Direct-link `libMoltenVK.a` ⇒ no Vulkan loader, no ICD.** MoltenVK exports the
  core `vk*` symbols itself. Do **not** request `VK_KHR_portability_enumeration`
  or set `…ENUMERATE_PORTABILITY_BIT` (loader-only; ICD returns
  `VK_ERROR_EXTENSION_NOT_PRESENT`). The only portability piece needed is the
  **device** extension `VK_KHR_portability_subset`.
- **apiVersion 1.2 is enough** for 1.4 ingestion (MoltenVK reports 1.2.334).
- **SPIR-V `pCode` must be 4-byte aligned** — `@embedFile` bytes are not; copy into
  a `u32` buffer.
- Link set that worked: `-lMoltenVK` + frameworks `Metal Foundation QuartzCore
  IOKit IOSurface CoreGraphics AppKit` + `-lc++`.
- **Toolchain present:** `spirv-val`/`spirv-as`/`spirv-dis` are already on PATH
  (SPIRV-Tools) — used to validate the exact Phase-6 transform before runtime.

### Phase 1 — Build plumbing — ✅ DONE (2026-07-13)
`-Dgpu-backend=vulkan` (enum option; default `dawn`, so `main` is untouched).
New `lib/gpu/vk.zig` = the `Vk` compute context (instance, device, queue,
host-visible memory type, command pool + reusable cmd buffer, descriptor pool).
No `vulkan-zig`/VMA yet — hand-declared extern `vk*` + persistent-mapped coherent
buffers made those unnecessary for compute (revisit for the render phase). Build
links `libMoltenVK` + Homebrew `vulkan-headers`; no zgpu/zglfw/Dawn on this path.
Dawn build verified still green.

### Phase 2 — Compute backend — ✅ DONE (core), 2026-07-13 — **delivers the 1.4 goal**
`lib/gpu/gpu_vk.zig` re-implements the window-less subset against `vk.zig`:
`gpuComputeRun`, `gpuCompute/Compute2`, `gpuBufferNew/Write/Read/ReadI`,
`gpuUniformNew`, `gpuComputeNew/NewU`, `gpuDispatch/DispatchLoop` — all real; the
render exports are stubs (Phase 3). Same 30-name FFI, so `lib/gpu.k` loads it
unchanged. Simplifications from MoltenVK unified memory: every buffer is
`HOST_VISIBLE|HOST_COHERENT` + persistently mapped (upload/readback = `memcpy`, no
staging); every op is synchronous (`vkQueueWaitIdle`), so the descriptor pool
resets per op (no fences). `vkCmdPipelineBarrier` (compute→compute) between
`dispatchLoop` passes.
**Validated end-to-end on the real ASR/nn/solver stack** (all match the Dawn
backend, tiny error): `computevk.k` (toy), and the 8 heavy tests ported from
`window.run[loop;0]` → `gpu.computeRun[{[x] demo[]}]` (a one-line tail swap that
runs on *both* backends, Dawn regression re-verified): `nn.k`
(GEMM/Softmax/LayerNorm/Linear/SiLU/GELU/FFN/MHSA/ConvMod ≤7e-7), `conformer.k`
(7e-7/3e-7), `weights.k` (round-trips exact, forward==forward), `gpusolve.k`
(SOR 2887.48 + scatter atomics), `stencil.k`, `relax.k`, `subsample.k`,
`frontend.k`; `tdt.k`/`detok.k` (host-only) unaffected. `clothgpu.k` renders →
Phase 3.

**Sync design (important, learned the hard way).** First attempt submitted each
`gpuDispatch` on its own command buffer with a `vkCmdPipelineBarrier` between —
correct on desktop Vulkan, but **MoltenVK/Metal only tracks memory hazards
*within* one command buffer**, so cross-submission barriers are a no-op and long
dispatch chains (the conformer encoder) raced. Caught by `weights.k`:
`forward(loaded)` ≠ `forward(direct)` for identical weights ⇒ nondeterminism ⇒
race. **Fix: deferred submission** — record the whole chain into ONE command
buffer, submit+wait only at readback (`sync()`), reset the transient
command/descriptor pools per batch (flush at `POOL_SETS=512`). Both correct *and*
faster (stencil's 22000-iter solver: 5.8s naive-sync → 0.83s). `sync()` is called
before every host read (`gpuBufferRead/ReadI`, one-shot `gpuCompute/Compute2`) and
before `gpuBufferWrite` overwrites mapped memory.

### Phase 3 — Windowed render backend (1–2 weeks) — the bulk. IN PROGRESS.

**Increment 1 — windowed foundation — ✅ DONE (2026-07-13).** `gpuRun` opens a
real Vulkan window and runs the event loop: GLFW (Homebrew, `-lglfw3`) for
window/input + `glfwCreateWindowSurface` for the `VK_EXT_metal_surface`
(`vk.initGlfwLoader()` points GLFW at MoltenVK's `vkGetInstanceProcAddr` — no
libvulkan loader). `Vk.initWindowed` = surface → present-capable graphics+compute
queue → device (`VK_KHR_swapchain`) → BGRA8 render pass (clear→present) →
swapchain/views/framebuffers → 2 frames-in-flight (acquire/render semaphores +
fences); `beginFrame`/`endFrame` acquire+clear+submit+present with
resize-recreate. The frame callback gets the same `{width;height;mx;my;time;events}`
props + events table as Dawn (input callbacks ported). **Same unified device drives
compute**: `gpu.runShader` inside a frame works (`3 6 9`), coexisting with the
render loop (separate frame command pool from the compute pool). Verified: visible
window stays open + presents; `INK_FRAMES=N` headless runs N frames + exits clean.
Not yet drawing anything — just clear+present.

**Increment 2 — basic mesh pipeline — ✅ DONE (2026-07-13).** Render pass gained a
D32 depth attachment (depth image recreated with the swapchain); dynamic
viewport/scissor. `Vk.createMeshPipeline` builds a graphics pipeline from
vertex+fragment SPIR-V with a vertex binding derived from the shader's Input vars
(`meshVtxLayout` ported: PinF32/V2/V3/V4 type-ids → 1/2/3/4 components), depth-test
on, alpha blend. `gpuMesh` compiles+caches; `gpuDrawMesh` accumulates vertices into
one shared vertex buffer (per-call byte offset, so mixed strides coexist) +
records draws into the frame render pass. **Snapshot path also landed** (part of
Phase 4): `INK_SNAP` copies the swapchain image → host buffer → PNG
(`vkCmdCopyImageToBuffer` + layout barriers, `png.zig`). **Verified pixel-identical
to Dawn**: `test/sphere.k` renders a shaded sphere at 50.0% frame coverage,
brightest `(158,173,188)` on both backends. Not yet: uniform/texture/instanced mesh
variants (`gpuDrawMeshU/T`, `gpuDrawInstanced*`, `gpuDrawGeom*` still stubs).

**Increment 2b (uniform meshes) — ✅ DONE (2026-07-13).** `gpuDrawMeshU` +
`shader.vertexU`: per-draw uniform block at @group(0) binding 0. `Vk` gained a
uniform DSL + one descriptor pool & host-visible uniform buffer *per frame in
flight* (reset in `beginFrame` after the fence, so in-flight sets aren't freed);
`meshUniformSet` reserves a 256-byte slot, uploads ≤32 floats, returns a set.
`gpuMesh` detects the uniform block (OpVariable storage-class 2) and includes the
DSL in the pipeline layout. **Verified pixel-identical to Dawn**: `test/sword.k`
(`shader.vertexU`+`mesh.drawU`, FBX model) renders at 0.7% coverage, brightest
`(159,162,167)` on both. (Bug fixed en route: an `mapped[off .. off+n*4]` slice
tripped a checked-overflow panic; use `mapped[off..][0..len]`.)

**Remaining increments:**
2c. **Textured/instanced meshes** — `gpuDrawMeshT` (textures @group(1)),
    `gpuUploadMesh`+`gpuDrawInstanced{,T}`/`gpuDrawGeom{Resident,T}`. Unblocks
    `scene`/`earth`/`clothpull`.
**Increment 3 (2D fill pipeline) — ✅ DONE (2026-07-13).** `fill.wgsl` → GLSL
(`lib/gpu/fill.vert`+`.frag`) → `fill.vert.spv`/`fill.frag.spv` via
`glslangValidator` (`brew install glslang`; `.spv` `@embedFile`'d — regen command
in the shader headers). Fill pipeline = fill vertex + frag, 6-binding descriptor
set (view+frag uniforms + 1×1 dummy texture/sampler ×2), no depth, alpha blend;
per-draw frag-uniform ring (per-frame pool, reset in `beginFrame`); 2D layer
recorded *before* meshes. `gpuTess` = CPU (`triangulate.zig`, verbatim).
**`gpuSpirv`/`gpuFillShader` custom-fragment path** = user dye.k fragment over the
fill vertex (`buildFillPipe` shared). **Verified pixel-identical to Dawn** (exact
per-channel): `eyes`, `circle` (SDF frag), `planes`, `drawing`, `typeset`, `demo`,
`edit`. `gpuWgsl` will be dropped at cutover.

**Increment 2c — textures + retained geometry — ✅ DONE (2026-07-13).**
`gpuTexture` (RGBA-expand + staging upload + layout transitions),
`Vk.createTexture`/`Texture`; `gpuMesh` detects `@group(1)` textures
(UniformConstant vars − 1 sampler) and builds the 2-set layout (uniform @group0 +
n images + shared sampler @group1); `texSet` per-draw; `gpuUploadMesh` (retained
vertex buffers) + `gpuDrawGeomT` (retained geom + uniform + textures).
**Verified pixel-identical to Dawn**: `test/earth.k` (5 textures, equirectangular,
retained mesh, uniform camera) at 96.9% coverage, per-channel identical.
**Still stubbed:** instancing (`gpuDrawInstanced`/`gpuDrawGeomResident`/
`gpuDrawInstancedT`, instance storage buffer @group0). Its test targets `scene`/
`clothpull` render all-black even on Dawn in headless snapshot mode, so they're not
snapshot-verifiable — deferred as low-value/unverifiable.

### Phase 6 — SPIR-V 1.4 — ✅ ACHIEVED LIVE (2026-07-13), the original goal
Rather than edit dye.k (which would break Dawn before cutover), the Phase-6
transform runs **live in the Vulkan backend**: `vk.maybeBump` (gated by
`INK_SPV14=1`) rewrites each compute module to 1.4 — version word `0x00010400` +
`OpEntryPoint` interface expanded to list every non-Function global variable —
right before `vkCreateShaderModule`. **The whole compute/neural-net stack runs on
genuine SPIR-V 1.4 through MoltenVK, bit-identical to 1.3:** `computevk`, `nn.k`
(GEMM/Softmax/LayerNorm/Linear/SiLU/GELU/FFN/MHSA ≤7e-7), `conformer.k` (7e-7/3e-7).
Proof it's real 1.4, not ignored: a bare version bump (no iface expansion) produces
**wrong** output (MoltenVK validates 1.4 semantics); the full transform is correct.
This is the migration's purpose delivered — Dawn's Tint reader refuses 1.4; MoltenVK
runs it. At final cutover (Phase 5), fold `maybeBump` into dye.k and drop the flag.

**Remaining (post-goal cleanup):** instancing (unverifiable, deferred); Phase 5
cutover (Vulkan default, delete Dawn/zgpu/`gpuWgsl`, make 1.4 unconditional);
Phase 7 self-host `fill` in dye.k; multi-time `-snap` scheduling.

Consider **dynamic rendering** later to drop explicit `VkFramebuffer` objects.
**Validated by:** `test/sphere.k`, `pbr.k`, `scene.k`, `eyes.k`, `circle.k`,
`planes.k`, `earth.k` (textures), `drawing.k`, `typeset.k`, `edit.k`,
`cloth*.k` (rendered).

### Phase 4 — Snapshot path (1–2 days)
Retarget the offscreen render-target used by `-snap` (INK_SNAP) to a Vulkan
offscreen `VkImage`; present via `vkCmdBlitImage` and read back via
`vkCmdCopyImageToBuffer` → host-visible → `png.zig` (no blit *shader*).
**Validated by:** `-snap` golden screenshots.

### Phase 5 — Cutover & cleanup (1–2 days)
Make `vulkan` the default (only) backend; delete Dawn/zgpu/zdawn/zpool, the lazy
dawn dep, `patches/`, and the `libtool` Dawn merge; rework `ink bundle`/`make
static` to link MoltenVK; **remove `gpuWgsl`** (export + `k_register`) and delete
`blit.wgsl`. Update `AGENT.md`, `CLAUDE.md`, memory, `.plan/`.

### Phase 6 — Flip to SPIR-V 1.4 (½ day) — the original ask
**Transform confirmed by Phase 0** (validated by `spirv-val --target-env
vulkan1.2` *and* run on MoltenVK). In `lib/dye.k`, for every emitter:
1. version word `0x00010300` → `0x00010400` (the 9 `hdr:` sites);
2. expand `OpEntryPoint` to append **all non-I/O global variables** referenced by
   the entry (StorageBuffer / Uniform / PushConstant vars — not just the
   Input/Output builtins). For `shader.compute` that meant adding the two
   StorageBuffer var ids; each emitter must list its own globals. `spirv-val`
   pinpoints any it's missing ("Interface variable id <N> … not listed as an
   interface").
Re-run `test/spirv.k` golden (bump expected version word + word counts) + the
Phase 2/3 suites. Note: pure passthrough render frags may need no new interface
entries; compute/stencil/scatter kernels always do.

### Phase 7 — Self-host the fill shader, delete the last non-SPIR-V source (2–4 days)
Re-author `fill.wgsl` as `lib/gpu/fill.k` in the ink shader dialect, compiled by
`dye.k` (§6 Track B). Extend `dye.k`'s fragment path as needed for fill-type
dispatch + SDF math. Delete the GLSL bridge source and the `glslc` build step.
**End state: every shader in the project is SPIR-V emitted by `dye.k` — zero
`.wgsl`/`.glsl`, no external shader compiler at build or runtime.** Validated by
the full render suite (byte-diff / visual parity vs the Track-A bridge output).

## 8. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| MoltenVK rejects our exact 1.4 SPIR-V | low | **Phase 0 proves it first**; fall back to 1.3-on-Vulkan (still removes Tint) |
| Vulkan verbosity balloons the port | high | use vulkan-zig + VMA + dynamic rendering; freeze the FFI so scope can't creep |
| Descriptor-pool sizing / per-frame lifetime bugs | med | ring of per-frame pools; validation layers on during dev |
| Sync/barrier correctness (compute loops, readback) | med | validation layers + `vkDeviceWaitIdle` fallbacks first, optimize later |
| GLFW Vulkan surface on macOS flaky | low | well-trodden `glfwCreateWindowSurface`+`VK_EXT_metal_surface` path |
| `ink bundle` static MoltenVK link | med | mirror the current `libtool` merge with MoltenVK's `.a` + frameworks |
| `fill` fragment can't be expressed in dye.k dialect (Phase 7) | med | GLSL bridge stays until dye.k is extended; Phase 7 is deferrable without blocking the migration |

## 9. Effort estimate

Realistically **~4–5 weeks** of focused single-dev work: Phase 0 ≈ 1 day, Phase 2
≈ 1 week (incl. plumbing), Phase 3 ≈ 1.5–2 weeks (the render backend is the mass),
Phases 4–6 ≈ few days, Phase 7 (self-host `fill`) ≈ 2–4 days. The compute half
(the part that delivers 1.4) is reachable in the **first week**; the render half
is the long tail; Phase 7 removes the last non-SPIR-V shader.

## 10. Decisions

**Settled:**
- **Scope = full renderer.** All phases (0–7); no dual-backend shortcut. Dawn is
  fully removed at Phase 5.
- **`gpuWgsl` = dropped.** Removed at Phase 5 (no in-tree caller).
- **Built-in shaders = SPIR-V-native end state.** `blit` deleted (fixed-function).
  `fill` via a temporary GLSL→SPIR-V build-time bridge (Phase 3), then re-authored
  in k/`dye.k` and the bridge deleted (Phase 7). Goal: zero `.wgsl`/`.glsl`, no
  external shader compiler at build or runtime.

**Still open (can be decided at Phase 1):**
1. **MoltenVK delivery** — static `.a` (best for `ink bundle`) vs Vulkan loader +
   ICD. Lean static.
2. **Cross-platform seam** — keep macOS-only (v1) but design `vk.zig`'s
   surface-creation/extension selection so Linux/Windows drop in later (small
   extra care now, since Vulkan is already portable — big future payoff). Lean
   "design the seam, ship macOS."

## 11. Recommended first action

Do **Phase 0** and nothing else until it passes. It is one throwaway file, ~1 day,
and it is the only step that converts "MoltenVK should accept our 1.4 SPIR-V" into
a verified fact. Everything after it is bounded, mechanical re-implementation
behind a frozen ABI.

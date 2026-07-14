# Changelog

## 2026-07-14
- **`9:`/`8:` io verbs** (kk increment 4, verb surface): the GPU is an io
  channel — `9: x` places (upload → descriptor `[gpu;t;n]`), `d 9: x`
  overwrites in place, `8: d` fetches, `n 8: d` fetches n. Implemented as
  `io.zig` trampolines to `gpu.hold`/`holdInto`/`fetch`/`fetchN` (new, in
  lib/gpu.k); `8:` added to the grammar (`9:` was a reserved stub); `!io`
  when lib/gpu.k isn't loaded.
- **`gpu.caps`** (completes kk increment 0): device capability dict from the
  live Vulkan device (`Vk.queryCaps` → `gpuCaps` FFI). M1 Pro/MoltenVK reports
  ALL of: subgroup arithmetic (32 lanes), descriptor indexing + runtime
  descriptor arrays, buffer device address, f16, and VK_EXT_shader_atomic_float
  f32 add — so subgroup reductions, bindless, and native float scatter-add are
  all on the table (features still need enabling at device creation to use).
- **Vulkan cutover** (kk increment 0 / migration Phase 5): Dawn/WebGPU backend
  deleted (`lib/gpu/gpu.zig`, `render.zig`, `fill.wgsl`, `blit.wgsl`,
  `patches/`, zon deps, `gpuWgsl`); raw Vulkan/MoltenVK (`gpu_vk.zig`) is the
  only backend; `zig build static` merges gpu+MoltenVK+GLFW into
  `libgpu-bundle.a` (11MB, was ~20MB). Run `make install` to refresh the stale
  Dawn dylib under `~/.ink`.
- **SPIR-V 1.4 native** (kk increment 2 / migration Phase 6): dye.k emits
  version `0x00010400` with the full-interface `OpEntryPoint` rule in all four
  assemblers (compute `kAsm`, fragment `buildMod`, `shader.vertexU`,
  `lib/instancing.k`); the `INK_SPV14`/`maybeBump` live transform is removed.
  12/12 kkgold modules pass `spirv-val --target-env vulkan1.2`; golden +
  walk3/nn/sphere/circle/eyes/earth/clothgpu all verified.
- **kk design** (`doc/design/kk.md`): plan for compiling idiomatic k to both
  SPIR-V and ink bytecode — io verbs `9:` (place on GPU) / `8:` (fetch), the
  k-primitive→compute rewrite table (each/gather/amend/fold/scan tiers), placed
  arrays as the data layer, SPIR-V 1.4 flip + caps-gated bindless, and the
  IR→FusedMap CPU backend (`bits`).
- **dye consolidation** (kk increment 1): the eight compute emitters in
  `lib/dye.k` (`shader.compute{,U,2}`, `shader.stencil{,U,IP}`,
  `shader.scatter`, `gpu.kernel`) are now thin wrappers over one shared
  prologue/assembler (`kAlloc`/`kGidX`/`kGidF`/`kElem`/`kStore`/`kAsm`);
  ~370 lines deleted, one `hdr:` site remains (prereq for the SPIR-V 1.4 flip).
  `gpu.kernel` with no accumulators no longer emits dead i32 types/constants.
  Oracle: `test/kkgold.k` module dumps (9/12 byte-identical, 3 improved),
  `spirv-val` on all, `walk3`/`nn`/`clothgpu`/`spirv.k` end-to-end.

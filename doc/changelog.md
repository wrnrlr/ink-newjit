# Changelog

## 2026-07-15
- **Monadic `%` = Shape** (the glyph was free since sqrt moved to the
  prelude; dyad stays divide): rectangular extent as an int vector, ragged
  lists stop at the first non-uniform level (`%(1 2;3 4;5 6)`→`3 2`,
  `%(1 2;3 4 5)`→`,2`, atoms→`!0`); inverse of reshape. New
  src/primitive/verb/shape.zig + unit tests. Placed-array descriptors gain
  `s: %x` — `9:` flattens nested rectangular input for upload and `8:`
  reshapes the readback, so `8: 9: (N;N)#x` round-trips (kk2.md §8-4).
- **Compute bodies compile through the neutral IR** (kk incr 3, the seam
  migration): kSeqIr builds typed SSA for every compute entry point and
  lowers it in build order. New IR ops: bufidx/igetb loads, setb/sadd/isetb
  effects, f2s conversions, bufp binding refs, and rsum/rmax/ndo/whileL as
  opaque region nodes (xRgn owner column; loop lowerers replay their owned
  nodes inside loopOpen/loopClose blocks; nesting via saved RK* phi globals).
  All 12 kkgold modules byte-identical to the retired direct path; golden,
  walk3, nn, clothgpu, baking, inference, fragment-IR all verified. The
  second backend (bits → FusedMap) and IR-level rewrites now have the full
  compute dialect to target.
- **Binding inference: `shader.kernel[fn]` + `gpu.pipeline[fn]`** (kk incr 3,
  bindings-from-the-lambda): params passed to scatterAdd/iget/iset are i32
  accumulators (must come first; warned otherwise), the last param is the
  thread index, the rest are f32 buffers. Byte-identical to
  `gpu.kernel[fn;nAcc;nBuf]` with the right counts. `gpu.pipeline[fn]`
  compiles lambda→SPIR-V→cached pipeline in one call (nbind published as
  KKnb). New gotcha documented in code: `kVal *kF[…]` is kVal TIMES kF
  (noun-adjacency); use kF1.
- **Host-global baking in kernels** (kk increment 3, first slice): a name in a
  dye kernel that isn't a param/local now resolves to the HOST global's current
  value, baked as an f32 constant at kernel-compile time — "host globals are
  invisible inside shaders" is gone, and with it the keep-in-sync-by-comment
  literals (clothgpu.k's `SC` now referenced directly in kCon/kApp). Unknown or
  non-scalar names warn and bake NaN (loud, since ink has no signal verb).
  Both compiler paths (compVar + IR xVar).
- **Fix: ReleaseFast GPU builds crashed at vkCreateInstance** — the release
  link dead-stripped static MoltenVK's ObjC selector metadata
  (`+[NSProcessInfo processInfo]: unrecognized selector`). `link_gc_sections =
  false` on libgpu.dylib (and `--no-gc-sections` in `ink bundle`'s link).
  Debug builds only worked because they don't gc sections.

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

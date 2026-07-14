# Changelog

## 2026-07-14
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

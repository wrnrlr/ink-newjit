# The FastLanes Compression Layout: Decoding >100 Billion Integers per Second with Scalar Code

**Authors:** Azim Afroozeh, Peter Boncz
**Venue:** VLDB 2023 / PVLDB Vol. 16, No. 9, pp. 2132–2144
**DOI:** 10.14778/3598581.3598587
**Sources:**
- PVLDB (open): https://www.vldb.org/pvldb/vol16/p2132-afroozeh.pdf
- Project: https://github.com/cwida/FastLanes

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section. The PVLDB PDF above is open access.

---

## Summary

FastLanes attacks a portability problem in SIMD compression: hand-written AVX-512 / NEON kernels
(à la SIMD-BP128) are fast but tied to one ISA and vector width. FastLanes defines a **data
layout** — a fixed "unified transposed" interleaving of values — such that *plain scalar code*
auto-vectorizes to near-peak on **any** SIMD width the compiler targets, and the same bytes
decode efficiently on GPUs too.

- Introduces a canonical **1024-value micro-block** and an "**interleaved / transposed**"
  arrangement of the bits so that the natural loop over lanes maps onto whatever the hardware's
  vector registers are, with no shuffles that depend on a specific width.
- Because it is a *layout* rather than an intrinsics kernel, one implementation is portable across
  SSE/AVX2/AVX-512/NEON/SVE and GPU threads — the compiler does the vectorization.
- Supports the usual lightweight schemes (bit-packing, FOR, delta, dictionary) expressed within
  this layout; reports >100 billion ints/sec decode with ordinary scalar C.
- Designed as the encoding substrate for a next-gen columnar format (see `kuschewski_2023_btrblocks.md`,
  same research group).

## Why it matters for Ink

FastLanes is the paper most specific to Ink's *combination* of a CPU runtime **and** a SPIR-V GPU
backend — its whole selling point is "one packed layout that decodes fast on CPU SIMD and on GPU
threads," which is exactly the seam Ink straddles.

- Ink's GPU compiler (`lib/spirv.k`, `lib/instancing.k`) uploads meshes/columns to the device; a
  FastLanes-encoded column could be transferred compressed and decoded in the shader, cutting the
  host↔device bandwidth that dominates the SPIR-V path (`project_gpu_texture_sampling`,
  `project_ink_gpu_uniforms_renderer`).
- The **1024-value micro-block** is a natural match for the chunk size in a chunked/fused CPU
  executor (`doc/research/columnar-execution.md`) — pick the executor's tile and the codec's block
  to be the same 1024 and decode-then-compute shares one loop nest.
- Zig's portable `@Vector` plus the fact that the runtime is compiled for the host arch means a
  FastLanes decoder can be written once in scalar/`@Vector` Zig and let the backend vectorize —
  precisely the portability the paper is selling, without per-ISA kernels.
- Preferred over raw SIMD-BP128 (`lemire_2015_simd_compression.md`) if Ink wants a *single* codec
  shared by the CPU verbs and the GPU shaders rather than two hand-tuned ones.

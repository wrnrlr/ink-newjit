# Decoding Billions of Integers Per Second Through Vectorization (SIMD-BP128 / FastPFOR)

**Authors:** Daniel Lemire, Leonid Boytsov (with later work incl. Nathan Kurz)
**Venue:** Software: Practice and Experience, Vol. 45, No. 1, 2015, pp. 1–29
**DOI:** 10.1002/spe.2203
**arXiv:** https://arxiv.org/abs/1209.2137
**Reference implementations:**
- FastPFOR (C++): https://github.com/lemire/FastPFor
- SIMDCompressionAndIntersection: https://github.com/lemire/SIMDCompressionAndIntersection

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section. The arXiv version is open access.

---

## Summary

The practical, SIMD-era realization of the lightweight-codec idea. Where Zukowski's PFOR was
scalar-superscalar, this line of work makes integer bit-packing and patched frame-of-reference
run on **SSE/AVX** at tens of billions of integers per second.

- **SIMD-BP128** packs integers in fixed-width bit blocks of 128 values, decoded with a handful
  of vector shift/mask/OR instructions per block — no per-value branches, fully data-parallel.
- **FastPFOR / SIMD-FastPFOR** add the patched-frame-of-reference exception handling on top of
  SIMD bit-packing, so real (non-uniform) integer distributions still pack tightly while decoding
  stays vectorized. A separate exception stream is applied in a second SIMD pass.
- Best paired with **delta coding** for sorted/monotonic columns (docid lists, timestamps,
  offsets, dictionary indices) — the paper studies SIMD delta + prefix-sum reconstruction.
- Establishes the modern benchmark methodology (bits/int vs decode-speed frontier) that later
  formats (FastLanes, BtrBlocks) measure themselves against.

## Why it matters for Ink

This is the concrete algorithm you would actually ship to compress an Ink integer column. Ink is
**i32/f32-only** (`feedback_ink_i32_f32_parser_quirks`), so integer bit-packing applies directly
to every `N<i32>` and to the dictionary-index / offset vectors that pervade the codebase:

- Interned-symbol columns (`src/noun/symbol.zig`, `S`/packed `KS` in `kabi`) are dictionary codes
  → SIMD-BP128 on the code stream.
- Offset/index vectors: shapefile CSR arrays (`project_shapefile_module`), USDC/FBX index tables,
  Parquet RLE/dictionary indices, `where`/`group` result indices — all monotone or small-range,
  ideal for delta + bit-pack.
- **Delta + prefix-sum** maps onto Ink primitives conceptually (`-':` deltas, `+\` scan); a native
  SIMD kernel would back those for compressed columns.

Two integration notes:

1. Zig has first-class `@Vector(N, T)`, so SIMD-BP128-style kernels can be written portably in the
   runtime (and the compiler targets the host arch) without intrinsics — a good fit for a
   `src/primitive/` codec module or a `lib/` native extension.
2. This is the CPU decoder that a FastLanes-style layout (`afroozeh_2023_fastlanes.md`) generalizes
   so the *same* packed bytes also decode on the GPU — relevant given Ink's SPIR-V backend.

# BtrBlocks: Efficient Columnar Compression for Data Lakes

**Authors:** Maximilian Kuschewski, David Sauerwein, Adnan Alhomssi, Viktor Leis
**Venue:** SIGMOD 2023 / PACMMOD Vol. 1, No. 2, Article 118
**DOI:** 10.1145/3589263
**Sources:**
- ACM DL: https://dl.acm.org/doi/10.1145/3589263
- Project: https://github.com/maxi-k/btrblocks

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section.

---

## Summary

BtrBlocks is a complete open columnar **storage format** (a faster, more compressible alternative
to Parquet/ORC for data-lake files) built on the lightweight-codec tradition. Its thesis: a good
format is not one codec but a **cascade of cheap encodings chosen by sampling**, tuned so that
decompression stays cheap enough to be bandwidth-bound rather than CPU-bound on cloud storage.

- A small palette of **lightweight schemes** — RLE, FOR/frame-of-reference, dictionary,
  **FSST** (string compression), **Pseudodecimal** (for floats/doubles), and bit-packing (using a
  FastLanes-style layout, `afroozeh_2023_fastlanes.md`).
- **Recursive / cascaded encoding**: the output of one scheme (e.g. dictionary codes, or FOR
  exceptions) is itself a column that gets compressed again, picking the best scheme at each level.
- A **sampling-based greedy scheme selector**: draw small samples from each column chunk, estimate
  compressed size + decode cost for each candidate encoding, pick the winner per chunk — no
  exhaustive trial, decisions are local and fast.
- Reports better compression ratios than Parquet/zstd *and* much faster decompression, the point
  being total scan time (I/O + decode) on analytical workloads.

## Why it matters for Ink

BtrBlocks is the blueprint if Ink ever wants its **own** on-disk / in-memory columnar format
instead of leaning on the native Parquet reader (`project_parquet_module`).

- It composes every other paper in this cluster: FastLanes bit-packing, FOR/delta and dictionary
  (Zukowski/Lemire), operate-on-encoded (Abadi) — BtrBlocks is how you assemble them into a real
  format with automatic per-chunk scheme choice.
- The **sampling scheme-selector** is the practical planner Ink lacks: given a homogeneous `N<T>`
  column plus the `ArrayFlags` (`ascending`/`distinct`) statistics Ink already tracks
  (`src/noun/array.zig`), pick RLE vs dictionary vs FOR vs bit-pack per chunk cheaply. This is the
  same cost-model role CLA plays for matrices (`elgohary_2016_compressed_linear_algebra.md`).
- **Pseudodecimal / float handling** is directly relevant: Ink is f32-heavy (GPU meshes, geometry
  from shp/fbx/usd/gltf), and float columns are the hard case for lightweight compression —
  BtrBlocks' float scheme is a concrete answer.
- **FSST** for strings maps onto Ink's interned-symbol columns (`src/noun/symbol.zig`, packed `KS`
  in `kabi`) as an alternative/complement to plain dictionary interning.
- Scope note: this is a *storage* concern (at-rest bytes), distinct from the *execution* concern
  the X100/roofline papers address. Sequence the work — get chunked/fused execution
  (`doc/research/columnar-execution.md`) landing first, then a BtrBlocks-style format feeds it
  compressed chunks.

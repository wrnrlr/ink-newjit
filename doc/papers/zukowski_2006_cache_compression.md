# Super-Scalar RAM-CPU Cache Compression

**Authors:** Marcin Zukowski, Sándor Héman, Niels Nes, Peter Boncz
**Venue:** ICDE 2006 (22nd International Conference on Data Engineering)
**DOI:** 10.1109/ICDE.2006.150
**Sources:**
- IEEE: https://ieeexplore.ieee.org/document/1617427
- CWI (open): https://ir.cwi.nl/pub/

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section.
>
> This one file covers **both** list items "Super-Scalar RAM-CPU Cache Compression" and
> "Super-Scalar Cache Compression" — they refer to the same ICDE 2006 work by Zukowski et al.

---

## Summary

A follow-on to X100 (`boncz_2005_x100.md`) that makes compression fast enough to sit *between RAM
and CPU cache*, not just between disk and RAM. The premise: because vectorized execution is
memory-bound (see `williams_2009_roofline.md`), decompressing on the way from RAM into cache is a
net win **only if decompression is faster than the DRAM bandwidth it saves** — which rules out
byte-oriented, branchy codecs (gzip, LZ) for this layer.

Contributions:

- Three **lightweight, super-scalar codecs** designed for high IPC and no data-dependent
  branches: **PFOR** (patched frame-of-reference), **PFOR-DELTA** (PFOR over deltas, for sorted /
  slowly-changing columns), and **PDICT** (patched dictionary).
- The **"patching"** trick: bit-pack the common case to a fixed narrow width; the rare outliers
  ("exceptions") that don't fit are stored separately in a linked list threaded through the
  exception slots and applied in a second, branch-free pass. This keeps the hot loop free of
  per-value conditionals — the key to superscalar throughput.
- Decompression is done **per X100 vector, in cache**, fused into the execution pipeline, so
  columns live compressed in RAM/L2 and are expanded just-in-time into L1.
- Shows multi-GB/s decode rates and end-to-end query speedups from the reduced memory traffic.

## Why it matters for Ink

This is the concrete codec layer under the Abadi paper's "compression-aware execution" thesis,
tuned for exactly Ink's memory-bound, vectorized regime.

- Ink's Parquet reader already carries a **PLAIN dictionary + RLE/bit-pack** path
  (`project_parquet_module`); PFOR/PFOR-DELTA/PDICT are the natural in-memory analogues for
  `N<i32>` / `N<u32>` columns and for compressing Parquet integer pages on ingest.
- The **patching** idea fits Ink's model well because columns are homogeneous `N<T>`
  (`src/noun/array.zig`) with known element type and length — the exception list can hang off the
  `Rc` header region the way flags already do (`ArrayFlags`).
- **Where it plugs in:** if Ink adopts chunked/fused execution (`doc/research/columnar-execution.md`),
  the per-chunk decode step is the right home for a PFOR kernel — decode a compressed chunk into
  an L1-resident scratch tile, run the fused verb chain, discard. That is the RAM-CPU cache
  compression pattern verbatim.
- **Do not** reach for gzip/zstd at this layer (Ink has those via the Parquet/image codecs) —
  the paper's whole point is that heavyweight codecs are too slow to beat DRAM bandwidth for
  in-cache use; use them only for on-disk / at-rest storage.

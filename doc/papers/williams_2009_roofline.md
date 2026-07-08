# Roofline: An Insightful Visual Performance Model for Multicore Architectures

**Authors:** Samuel Williams, Andrew Waterman, David Patterson
**Venue:** Communications of the ACM, Vol. 52, No. 4, April 2009, pp. 65–76
**DOI:** 10.1145/1498765.1498785
**Sources:**
- ACM DL: https://dl.acm.org/doi/10.1145/1498765.1498785
- Berkeley EECS TR (open): https://www2.eecs.berkeley.edu/Pubs/TechRpts/2008/EECS-2008-134.html

> **NOTE — summary, not verbatim.** The full text was not fetched in this environment. This file records verified bibliographic metadata plus a summary written from knowledge and an Ink-relevance section. Retrieve the open-access Berkeley TR above for the full paper.

---

## Summary

Roofline is a visual performance model that bounds the attainable performance of a
kernel on a given machine as `min(peak_flops, peak_bandwidth × arithmetic_intensity)`.

- **Arithmetic intensity (AI)** = FLOPs performed per byte moved from DRAM (flops/byte).
- The model is a log-log plot: a slanted line of slope = peak memory bandwidth, meeting a
  horizontal line = peak compute. Their intersection is the **ridge point**.
- A kernel to the left of the ridge is **memory-bound** (raising AI or bandwidth helps);
  to the right it is **compute-bound** (only more FLOP/s helps).
- Successive "ceilings" (no-SIMD, no-FMA, no-NUMA, no-prefetch) show how far specific
  optimizations can move a kernel, giving an ordered optimization checklist per kernel.

## Why it matters for Ink

Roofline is the *lens* for the whole columnar-execution cluster of papers, not a technique to
implement. Ink's core loops are low-AI: each verb (`+`, `*`, `<`) reads one or two columns,
does one cheap op per element, and writes a full column back — see the elementwise kernels in
`src/primitive/verb/helper.zig` (`kernelVec2` allocates a full `N(R)` result and streams the
input slices once). At ~1 flop per 4–12 bytes touched, these are firmly memory-bound.

Consequences the model makes explicit:

1. **Compression pays.** Because we are bandwidth-bound, storing columns bit-packed / RLE and
   paying extra ALU cycles to decode *raises* effective throughput — this is the Roofline
   justification for the Zukowski / Lemire / FastLanes / BtrBlocks papers.
2. **Fusion pays.** A chain like `a+b*c` currently materializes two full temporaries to DRAM.
   Fusing verbs so a cache-sized chunk stays in registers across ops raises AI directly — the
   X100 idea (`boncz_2005_x100.md`), sketched for Ink in `doc/research/columnar-execution.md`.
3. **SIMD is a ceiling, not the floor.** Vectorizing the scalar kernels only helps once we are
   compute-bound within a chunk; for memory-bound whole-column ops it barely moves the line.
   Roofline tells you to fix bandwidth (fusion/compression) *before* reaching for `@Vector`.

Use it as a triage tool: measure a workload's AI, place it on the plot for the target CPU, and
only invest in optimizations whose ceiling the kernel can actually reach.

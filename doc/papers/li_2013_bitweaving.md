# BitWeaving: Fast Scans for Main Memory Data Processing

**Authors:** Yinan Li, Jignesh M. Patel
**Venue:** SIGMOD 2013, pp. 289–300
**DOI:** 10.1145/2463676.2465322
**Sources:**
- ACM DL: https://dl.acm.org/doi/10.1145/2463676.2465322
- UW-Madison (open): https://pages.cs.wisc.edu/~jignesh/publ/BitWeaving.pdf

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section. The UW PDF above is open access.

---

## Summary

BitWeaving accelerates **predicate scans** (`col < c`, `col = c`, range/`BETWEEN`) over
column-store data by exploiting *intra-word parallelism*: pack many narrow column codes into
machine words and evaluate the predicate on all of them at once with ordinary ALU arithmetic —
no SIMD intrinsics required, and a full word (64 values at 1 bit, or several at k bits) per
instruction.

Two layouts:

- **BitWeaving/H** ("horizontal"): several codes packed per word with delimiter bits; a
  functional-programming-style sequence of add/mask/shift operations computes a result bit per
  code, producing a **bit-vector of matches** directly.
- **BitWeaving/V** ("vertical"): bit-sliced — bit *i* of every code stored contiguously across a
  word. Predicates evaluate most-significant-bit-first and **early-exit** whole words once the
  comparison is decided, so lower bit-planes need not be read for many values.

Both produce a packed result bit-vector that downstream operators consume, and both scan
compressed (narrow-code) data directly — combining Abadi's compression-aware execution with
word-parallel evaluation. Reported multi-billion-codes/sec scan rates.

## Why it matters for Ink

BitWeaving is the technique behind fast `where`/mask/select on Ink's boolean and small-integer
columns:

- Ink's comparison verbs and `&` require `B`/`I` vectors (`feedback_ink_i32_f32_parser_quirks`),
  and produce boolean masks consumed by `where.zig` / `select.zig` / `weedout.zig`. A `B` column
  is already a bit-vector's worth of information stored one-byte-per-bit; BitWeaving/H is how you
  make `&(x>c)` evaluate ~64 elements per instruction and emit a packed mask.
- **BitWeaving/V early-exit** suits range predicates on `N<i32>` where most values are decided by
  the top few bits — a good match for scanning large columns in `find.zig` / `member.zig`.
- Pairs naturally with a compressed-column story: the bit-sliced layout is *itself* a compression
  (narrow codes), so a scan never materializes dense `i32` just to compare. This is the scan-side
  counterpart to the pack-side codecs in `lemire_2015_simd_compression.md`.
- Practical caveat for Ink: producing a *packed* result bit-vector (rather than the current
  one-`bool`-per-element `B`) would be a new representation; worth it only for scan-heavy
  workloads, and best introduced alongside the chunked executor
  (`doc/research/columnar-execution.md`) so masks stay in cache.

# Integrating Compression and Execution in Column-Oriented Database Systems

**Authors:** Daniel Abadi, Samuel Madden, Miguel Ferreira
**Venue:** SIGMOD 2006, pp. 671–682
**DOI:** 10.1145/1142473.1142548
**Sources:**
- ACM DL: https://dl.acm.org/doi/10.1145/1142473.1142548
- MIT (open): https://dspace.mit.edu/handle/1721.1/34524 (C-Store project)

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section.

---

## Summary

The central thesis: in a column store, compression is not just a storage-size win — the query
executor should be **compression-aware** and operate on encoded data directly, without an eager
decompression step.

- Surveys lightweight column encodings: **run-length (RLE)**, **bit-vector**, **dictionary**,
  and **frame-of-reference / delta** — chosen so decoding is cheap and, crucially, so operators
  can run *on the compressed form*.
- Key idea: expose compression to operators through an abstraction so that, e.g., a `SUM` or a
  predicate scan over an RLE column processes one run instead of N values, and a join over
  dictionary-coded columns compares integer codes instead of strings.
- Introduces the distinction between **compression-oblivious** (decode-then-run) and
  **compression-aware** operators, and shows the latter give both space and *time* wins because
  they touch fewer bytes and do less work.
- Notes that **sorted / clustered** columns compress far better (long RLE runs), tying physical
  layout to compressibility.

## Why it matters for Ink

Ink already has the two ingredients this paper combines: columnar storage (`N<T>` columns,
`utable` keyed tables, dict-of-columns SoA) and a native Parquet reader that decodes PLAIN /
dictionary / RLE pages (`project_parquet_module`). Today those encodings are decoded eagerly into
dense `N<T>` before any verb runs.

Directions this paper suggests for Ink:

1. **Operate on encoded columns.** A `where`/`&`-style predicate scan (`src/primitive/verb/where.zig`,
   `find.zig`) over a dictionary column can compare interned codes, and over an RLE column can
   emit run boundaries directly. Ink's interned symbol pool (`src/noun/symbol.zig`) is already a
   dictionary encoding for `S` columns — comparisons on `S` are integer-code comparisons, which is
   exactly this paper's dictionary-join optimization.
2. **RLE-aware reductions.** `+/`, `#`, group/`freq` over a run-length column can weight by run
   length instead of expanding — relevant to `src/primitive/derived/reduce.zig` and
   `verb/group.zig`/`freq.zig`.
3. **Keep the sort/distinct flags.** `array.zig` `ArrayFlags` already tracks `ascending`/`distinct`;
   this paper is the argument for using those flags to pick RLE and to short-circuit operators.

It is the conceptual bridge from "Parquet is compressed on disk" to "columns stay compressed in
memory and verbs run on them" — the higher-level goal that the Zukowski/Lemire/FastLanes papers
supply the concrete codecs for.

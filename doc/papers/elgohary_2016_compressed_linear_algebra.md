# Compressed Linear Algebra for Large-Scale Machine Learning

**Authors:** Ahmed Elgohary, Matthias Boehm, Peter J. Haas, Frederick R. Reiss, Berthold Reinwald
**Venue:** VLDB 2016 / PVLDB Vol. 9, No. 12, pp. 960–971 (extended version in VLDB Journal 2018)
**DOI:** 10.14778/2994509.2994515
**Sources:**
- PVLDB (open): https://www.vldb.org/pvldb/vol9/p960-elgohary.pdf
- Apache SystemDS/SystemML implementation: https://systemds.apache.org/

> **NOTE — summary, not verbatim.** Full text not fetched here. Verified metadata + summary from knowledge + Ink-relevance section. The PVLDB PDF above is open access.

---

## Summary

CLA carries the "compression-aware execution" idea (Abadi) from relational scans into **linear
algebra**: it executes matrix operations — most importantly matrix-vector and vector-matrix
products, the inner loop of iterative ML (gradient descent, conjugate gradient, etc.) —
**directly on compressed matrices**, so the compression ratio translates into a proportional
speedup rather than being lost to an eager decompress.

- Compresses **column-wise** with lightweight, value-based encodings (offset-list / RLE /
  dictionary-of-distinct-values per column group), chosen to preserve the ability to compute.
- Redefines the LA kernels (matrix-vector multiply, transpose-multiply, element-wise ops,
  aggregates) to operate over the compressed representation — e.g. multiply the vector against
  each distinct value once and distribute via the offset lists, instead of touching every cell.
- Includes a **sampling-based cost model** that picks per-column-group encodings automatically
  and falls back to dense where compression would not help.
- Wins are largest for the tall-and-skinny, low-distinct-value matrices common in ML feature
  data, giving both memory savings (fit bigger data in RAM) and compute speedups.

## Why it matters for Ink

CLA is the bridge from "columnar database compression" to "array-language numerics," which is
squarely Ink's territory: an array language is a natural host for linear algebra, and the memory
model (`N<T>` columns, dict-of-columns tables, COW) is what CLA assumes.

- Ink already does `mmul`-style products via `/:` outer-product patterns
  (`feedback_ink_closures`). CLA shows the same operations can run on compressed operands — the
  matrix-vector kernel over dictionary/offset-encoded columns is the pay-off case.
- The **per-column-group encoding + sampling cost model** aligns with Ink's homogeneous columns
  and existing `ArrayFlags` (distinct/ascending) — those flags are exactly the cheap statistics a
  CLA-style planner needs to decide RLE vs dictionary vs dense.
- Ties the compression cluster together: CLA is what makes the Lemire/BitWeaving/BtrBlocks column
  codecs *useful for computation*, not just storage — the reason to care about compression in an
  array language rather than only in a Parquet reader.
- Longer-term, it complements the GPU path: compressed matrix-vector products reduce the
  host↔device bytes that dominate the SPIR-V backend's cost.

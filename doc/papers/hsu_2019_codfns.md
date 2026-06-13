# A Data Parallel Compiler Hosted on the GPU

**Author:** Aaron W. Hsu
**Advisor:** Andrew Lumsdaine
**Type:** Doctoral Dissertation (Ph.D.) — Indiana University, School of Informatics, Computing, and Engineering, November 2019
**Subjects:** compilers; tree transformations; GPU; APL; array programming
**Handle / record:** https://hdl.handle.net/2022/24749 · https://scholarworks.iu.edu/dspace/items/3ab772c9-92c9-4f59-bd95-40aff99e8c7a
**Full PDF (open access):** https://scholarworks.iu.edu/bitstreams/dcbd5240-8454-4533-bc0c-ac3ee7628b8e/download — "Hsu Dissertation.pdf", 29.26 MB
**Related project:** Co-dfns compiler — https://github.com/Co-dfns/Co-dfns

> **Note on this rendering.** This is the dissertation that the Co-dfns work is based on. The source is a single ~29 MB, full-length dissertation PDF; reproducing the entire body verbatim as markdown is impractical through automated extraction, so this file captures the **verbatim abstract** and complete bibliographic metadata, plus a relevance note for the array-language → GPU transpiler project. The full text is freely downloadable at the open-access link above. If you want, I can pull specific chapters (e.g. the compiler-architecture or performance chapters) into markdown on request.

---

## Abstract (verbatim)

This work describes a general, scalable method for building data-parallel by construction tree transformations that exhibit simplicity, directness of expression, and high-performance on both CPU and GPU architectures when executed on either interpreted or compiled platforms across a wide range of data sizes, as exemplified and expounded by the exposition of a complete compiler for a lexically scoped, functionally oriented programming commercial language. The entire source code to the compiler written in this method requires only 17 lines of simple code compared to roughly 1000 lines of equivalent code in the domain-specific compiler construction framework, Nanopass, and requires no domain specific techniques, libraries, or infrastructure support. It requires no sophisticated abstraction barriers to retain its concision and simplicity of form. The execution performance of the compiler scales along multiple dimensions: it consistently outperforms the equivalent traditional compiler by orders of magnitude in memory usage and run time at all data sizes and achieves this performance on both interpreted and compiled platforms across CPU and GPU hardware using a single source code for both architectures and no hardware-specific annotations or code. It does not use any novel domain-specific inventions of technique or process, nor does it use any sophisticated language or platform support. Indeed, the source does not utilize branching, conditionals, if statements, pattern matching, ADTs, recursions, explicit looping, or other non-trivial control or dispatch, nor any specialized data models.

## Relevance to the array-language → SPIR-V / polyhedral project (orientation)

This dissertation is the array-language-native counterpoint to the polyhedral papers in this folder. Where Tiramisu, PPCG, Pluto and isl reason about affine loop nests and schedules, Hsu's approach starts from an array language (a subset of Dyalog APL) and expresses the *entire compiler* — including its AST representation and tree transformations — as flat, data-parallel array operations that run on the GPU with no branching, recursion, or explicit loops. The compiler (Co-dfns) represents the program AST itself in a columnar, array-of-nodes form and rewrites it with rank-polymorphic primitives (scans, reductions, gather/scatter via index vectors), which is precisely the style a K/APL/BQN transpiler would use for its own internal passes.

Two takeaways for the project: (1) it is a concrete demonstration that array-programming primitives map efficiently onto GPU execution without a polyhedral layer — a useful contrast and sanity check against the polyhedral route; and (2) its data structures for representing and transforming trees as arrays are directly applicable to building the front-end/IR of an array-language compiler, independent of whether the back-end ultimately uses a polyhedral scheduler or flat data-parallel lowering to SPIR-V.

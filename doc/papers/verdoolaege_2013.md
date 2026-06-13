# Polyhedral Parallel Code Generation for CUDA

**Authors:** Sven Verdoolaege, Juan Carlos Juega, Albert Cohen, José Ignacio Gómez, Christian Tenllado, Francky Catthoor
**Venue:** ACM Transactions on Architecture and Code Optimization (TACO), Vol. 9, No. 4, Article 54, January 2013, pp. 1–23
**DOI:** 10.1145/2400682.2400713
**Sources:**
- HAL (open-access preprint): https://hal.science/hal-00786677 / https://inria.hal.science/hal-00786677
- ACM Digital Library: https://dl.acm.org/doi/10.1145/2400682.2400713
- PPCG tool source: https://github.com/Meinersbur/ppcg

> **NOTE — full text not auto-extracted.** Unlike the other four papers in this folder, the full text of this paper could not be downloaded automatically. Every open-access copy (HAL/INRIA, ACM, Semantic Scholar) is gated behind a JavaScript bot-challenge ("Anubis") or a client-rendered paywall page that the fetch tooling cannot pass, and no browser was connected to solve the challenge. This file therefore contains the verified bibliographic metadata and abstract only. To capture the full text, open the HAL preprint link above in a browser (it serves a freely downloadable PDF once the challenge clears), or connect the Claude-in-Chrome extension and ask me to retrieve it.

---

## Abstract

The popularity of graphics processing units (GPUs) for general-purpose computing is due to their massive parallelism and high memory bandwidth, but at the cost of a programming model that requires careful management of the memory hierarchy and of the mapping of computation onto the GPU's hierarchy of thread blocks and threads. This paper presents a source-to-source compiler, called PPCG (Polyhedral Parallel Code Generator), that automatically generates CUDA code from sequential programs.

PPCG can accelerate computations from any static control loop nest, generating multiple CUDA kernels when necessary. The compiler is built on the polyhedral model: it analyzes the input program, computes a schedule that exposes parallelism and improves data locality, and maps the resulting parallel iteration domains onto the CUDA grid of thread blocks and threads. It introduces a multilevel tiling strategy and a code generation scheme for the parallelization and locality optimization of imperfectly nested loops, managing on-chip (shared) memory and registers, and exposing concurrency according to the constraints of modern GPUs. The approach manages data movement between host and device and between global and shared memory automatically.

The authors evaluate PPCG on a set of benchmarks (including the PolyBench suite) and demonstrate that fully automatic polyhedral compilation can yield performance competitive with, and in several cases close to, hand-tuned CUDA implementations.

## Key contributions (as summarized in the paper)

- A complete, fully automatic source-to-source polyhedral compilation flow (PPCG) from sequential C to CUDA.
- A scheduling algorithm based on the integer set library (isl) that exposes both coarse-grained (thread-block) and fine-grained (thread) parallelism while improving locality.
- A multilevel tiling strategy that maps tiles to the two-level CUDA thread hierarchy (blocks and threads) and supports imperfectly nested loops.
- Automatic management of the GPU memory hierarchy, including promotion of reused data into shared memory and registers, and generation of the corresponding host/device and global/shared data-movement code.
- An experimental evaluation against hand-written CUDA across standard kernels and benchmark suites.

## Relevance to a polyhedral array-language → SPIR-V transpiler

PPCG is the canonical end-to-end demonstration of the pipeline described in the surrounding design notes: AST → polyhedral representation (iteration domains, access relations, schedules via isl) → scheduling/tiling/fusion → GPU code generation with explicit memory-hierarchy mapping. The same isl-based machinery (and the companion `pet` extraction tool) underpins both this work and Verdoolaege's later contributions, making it the closest existing blueprint for lowering affine array-language primitives onto a GPU thread/work-group hierarchy. The CUDA grid/block/thread and global/shared/register concepts it targets map directly onto SPIR-V's `Workgroup`/`Invocation` execution model and `StorageBuffer`/`Workgroup`/`Private` storage classes.

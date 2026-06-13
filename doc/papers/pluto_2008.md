# A Practical Automatic Polyhedral Parallelizer and Locality Optimizer

**Authors:** Uday Bondhugula, Albert Hartono (Ohio State University); J. Ramanujam (Louisiana State University); P. Sadayappan (Ohio State University)
**Venue:** Proceedings of the 29th ACM SIGPLAN Conference on Programming Language Design and Implementation (PLDI 2008), Tucson, Arizona, June 7–13 2008, pages 101–113
**DOI:** 10.1145/1375581.1375595
**Source:** https://www.ece.lsu.edu/jxr/Publications-pdf/pldi08.pdf

> **Note on this rendering.** This is a faithful prose rendering of the PLUTO paper. The source PDF's matrices, constraint systems, multi-line equations, and several wide code listings were extracted as garbled runs of isolated digits and symbols; those blocks are collapsed here into bracketed placeholders such as `[matrix / equation — see source PDF]` while all readable prose, algorithms, and the full reference list are reproduced. For the exact formal statements, consult the source PDF.

---

## Abstract

We present the design and implementation of an automatic polyhedral source-to-source transformation framework that can optimize regular programs (sequences of possibly imperfectly nested loops) for parallelism and locality simultaneously. Through this work, we show the practicality of analytical model-driven automatic transformation in the polyhedral model. Unlike previous polyhedral frameworks, our approach is an end-to-end fully automatic one driven by an integer linear optimization framework that takes an explicit view of finding good ways of tiling for parallelism and locality using affine transformations. The framework has been implemented into a tool to automatically generate OpenMP parallel code from C program sections. Experimental results from the tool show very high performance for local and parallel execution on multi-cores, when compared with state-of-the-art compiler frameworks from the research community as well as the best native production compilers. The system also enables the easy use of powerful empirical/iterative optimization for general arbitrarily nested loop sequences.

**Categories and Subject Descriptors:** D.3.4 [Programming Languages]: Processors—Compilers, Optimization, Code generation

**General Terms:** Algorithms, Design, Experimentation, Performance

**Keywords:** Automatic parallelization, Locality optimization, Polyhedral model, Loop transformations, Affine transformations, Tiling

## 1. Introduction and Motivation

Current trends in microarchitecture are increasingly towards larger numbers of processing elements on a single chip. This has made parallelism and multi-core processors mainstream. The difficulty of programming these architectures to effectively tap the potential of multiple on-chip processing units is a significant challenge. Among several approaches to addressing this issue, one that is very promising but simultaneously very challenging is automatic parallelization, which requires no effort on the part of the programmer and is therefore very attractive.

Many compute-intensive applications spend most of their execution time in nested loops. The polyhedral model provides a powerful abstraction to reason about transformations on such loop nests by viewing a dynamic instance (iteration) of each statement as an integer point in a well-defined space called the statement's polyhedron. With such a representation for each statement, and a precise characterization of inter- or intra-statement dependences, it is possible to reason about the correctness of complex loop transformations in a completely mathematical setting relying on machinery from linear algebra and linear programming. The transformations finally reflect in the generated code as reordered execution with improved cache locality and/or loops that have been parallelized. The polyhedral model is applicable to loop nests in which the data access functions and loop bounds are affine combinations (a linear combination with a constant) of the enclosing loop variables and parameters. While a precise characterization of data dependences is feasible for programs with static control structure and affine references/loop-bounds, codes with non-affine array access functions or dynamic control can also be handled, but only with conservative assumptions on some dependences.

The task of program optimization (often for parallelism and locality) in the polyhedral model may be viewed in terms of three phases: (1) static dependence analysis of the input program, (2) transformations in the polyhedral abstraction, and (3) generation of code for the transformed program. Significant advances were made in the past decade on dependence analysis and code generation, but the approaches suffered from scalability challenges. Recent advances in dependence analysis and, more importantly, in code generation have solved many of these problems, resulting in polyhedral techniques being applied to code representative of real applications like the spec2000fp benchmarks, and have made the polyhedral model practical in production compiler contexts as a flexible and powerful representation to compose and apply transformations. The key missing step has been the demonstration of a scalable and practical approach for automatic transformation for parallelization and locality. Our work addresses this by developing a compiler, based on the theoretical framework we previously proposed, to enable end-to-end fully automatic parallelization and locality optimization.

Tiling is a key transformation in optimizing for parallelism and data locality. Tiling for locality requires grouping points in an iteration space into smaller blocks (tiles) allowing reuse in multiple directions when the block fits in a faster memory (registers, L1, or L2 cache). Tiling for coarse-grained parallelism involves partitioning the iteration space into tiles that may be concurrently executed on different processors with a reduced frequency and volume of inter-processor communication: a tile is atomically executed on a processor with communication required only before and after execution. One of the key aspects of our transformation framework is to find good ways of performing tiling.

Existing automatic transformation frameworks have one or more drawbacks that limit their effectiveness. A common significant problem is the lack of a realistic cost function to choose among the large space of legal transformations suitable for coarse-grained parallel execution. Most previously proposed approaches also do not consider locality and parallelism together, and comprehensive performance evaluation on parallel targets using a range of test cases has not been done using a powerful and general model like the polyhedral model.

This paper presents the end-to-end design and implementation of PLUTO, a parallelization and locality optimization tool. Finding good ways to tile for parallelism and locality directly through an affine transformation framework is the central idea. Our approach is thus a departure from scheduling-based approaches as well as partitioning-based approaches (due to incorporation of more concrete optimization criteria), though it is built on the same mathematical foundations and machinery. We show how tiled code generation for statement domains of arbitrary dimensionalities under statement-wise affine transformations is done for local and shared-memory parallel execution. Because our transformation system operates entirely in the polyhedral abstraction, it is not limited to C or Fortran code, but could accept any high-level language from which polyhedral domains can be extracted and analyzed.

*Figure 1 in the source shows the polyhedral representation of a simple two-loop code: its statement domains, the data dependence graph, the dependence polyhedron for the S1→S2 edge, the statement-wise transformation, and the resulting transformed code. [matrices / code — see source PDF]*

The rest of the paper is organized as follows. Section 3 provides an overview of the theoretical framework for automatic transformation. Sections 4 and 5 discuss design considerations and techniques for generation of efficient tiled shared-memory parallel code. Section 6 describes the implemented system. Section 7 provides experimental results. Section 8 discusses related work, and Section 9 presents conclusions.

## 2. Background and Notation

This section provides background on the polyhedral model. (All row vectors are typeset in bold in the original.)

### 2.1 The Polyhedral model

**Definition 1 (Affine Hyperplane).** The set X of all vectors x ∈ Zⁿ such that h·x = k, for k ∈ Z, is an affine hyperplane. A hyperplane is a higher-dimensional analog of a (2-d) plane in three-dimensional space. The set of parallel hyperplane instances corresponding to different values of k is characterized by the vector h which is normal to the hyperplane. Two vectors x₁ and x₂ lie in the same hyperplane if h·x₁ = h·x₂.

**Definition 2 (Polyhedron).** The set of all vectors x ∈ Zⁿ such that Ax + b ≥ 0, where A is an integer matrix, defines a (convex) integer polyhedron. A polytope is a bounded polyhedron.

**Polyhedral representation of programs.** Given a program, each dynamic instance of a statement S is defined by its iteration vector i, which contains values for the indices of the loops surrounding S, from outermost to innermost. Whenever the loop bounds are linear combinations of outer loop indices and program parameters (typically symbolic constants representing problem sizes), the set of iteration vectors belonging to a statement defines a polytope. Let D_S represent the polytope and let its dimensionality be m_S. Let p be the vector of program parameters.

**Polyhedral dependences.** The dependence model is one of exact affine dependences. Dependences are determined precisely through dataflow analysis, but the framework considers all dependences including anti (write-after-read), output (write-after-write) and input (read-after-read) dependences — i.e., input code does not require conversion to single-assignment form. The Data Dependence Graph (DDG) is a directed multi-graph with each vertex representing a statement, and an edge e ∈ E from node Sᵢ to Sⱼ representing a polyhedral dependence from a dynamic instance of Sᵢ to one of Sⱼ. It is characterized by a polyhedron Pₑ, called the dependence polyhedron, that captures the exact dependence information corresponding to e. Letting s be the source iteration and t the target iteration of a dependence edge e, it is possible to express the source iteration as an affine function of the target iteration (the *h-transformation*, denoted hₑ), i.e. s = hₑ(t). The equalities corresponding to the h-transformation are part of the dependence polyhedron and can be used to reduce its dimensionality.

A one-dimensional affine transform for statement S_k is defined by an affine form `φ_Sk(i) = [c₁ … c_mSk]·i + c₀, with cᵢ ∈ Z` (Equation 1). φ_Sk can also be called an affine hyperplane, or a *scattering function* when dealing with the code generator. A multi-dimensional affine transformation for a statement is represented by a matrix with each row being an affine hyperplane.

**Definition 3 (Dependence satisfaction).** An affine dependence with polyhedron Pₑ is satisfied at a level l iff, for all preceding levels k (1 ≤ k ≤ l−1) the transformed difference is ≥ 0 over Pₑ, and at level l the difference is ≥ 1 over Pₑ. [formal inequalities — see source PDF]

## 3. Overview of Automatic Transformation Approach

This section gives an overview of the theoretical framework for automatic transformation (full details in the authors' companion report [8]).

### 3.1 Legality of tiling multiple domains with affine dependences

**Lemma 1.** Let φ_Si be a one-dimensional affine transform for statement Sᵢ. For {φ_S1, φ_S2, …, φ_Sk} to be a legal (statement-wise) tiling hyperplane, the following should hold for each edge e ∈ E:

```
φ_Sj(t) − φ_Si(s) ≥ 0,  for all ⟨s,t⟩ ∈ Pe        (Equation 2)
```

This is a generalization of the classic condition proposed by Irigoin and Triolet (h^T·R ≥ 0) for the legality of tiling a single domain. The tiling of a statement's iteration space by a set of hyperplanes is legal if each tile can be executed atomically and a valid total ordering of the tiles can be constructed — i.e., there exist no two tiles that depend on each other. This generalizes to multiple iteration domains with affine dependences and possibly different dimensionalities arising from imperfectly nested input.

Two statement-wise 1-d affine transforms that satisfy (2) represent rectangularly tilable loops in the transformed space; a tile is formed by aggregating a group of hyperplane instances. Due to (2), if such a tile is executed on a processor, communication is needed only before and after its execution; and if executed with its data fitting in a faster memory, reuse is exploited in multiple directions. Hence any solution to (2) represents a common dimension (for all statements) in the transformed space with both inter- and intra-statement affine dependences in the forward direction along it.

**Partial tiling at any depth.** The legality condition (2) is imposed on all dependences; but if imposed only on dependences not satisfied up to a certain depth, the independent φ's that satisfy the condition represent tiling hyperplanes at that depth — i.e., tiling at that level is legal.

### 3.2 Cost function, bounding approach and minimization

Consider the affine form `δe(s,t) = φ_Sj(t) − φ_Si(s)` over ⟨s,t⟩ ∈ Pₑ (Equation 3). This function is the number of hyperplanes the dependence e traverses along the hyperplane normal φ. If φ is used as a *space* loop to generate tiles for parallelization, this is a factor in the communication volume; if φ is used as a *sequential* loop, it measures the reuse distance. An upper bound on this function bounds the number of hyperplanes communicated at tile boundaries (equivalently, cache misses at L1/L2 tile edges, or L1 loads for a register tile). Of particular interest is reducing the function to a constant or to zero (free of a parametric component) by choosing a suitable direction for φ: this yields constant boundary communication or no communication for that hyperplane.

Minimizing this cost function directly yields an objective non-linear in loop variables and hyperplane coefficients. The difficulty is overcome with a *bounding function* approach that allows applying the Farkas Lemma and casting the objective into an ILP formulation. Since the loop variables can themselves be bounded by affine functions of the parameters, one can always find an affine form `v(p) = u·p + w` in the program parameters that bounds δₑ(s,t) for every dependence edge:

```
φ_Sj(t) − φ_Si(s) ≤ v(p),   i.e.   v(p) − δe(s,t) ≥ 0,   ⟨s,t⟩ ∈ Pe, ∀e ∈ E    (Equation 4)
```

Such a bounding approach was first used by Feautrier, but for a different purpose (minimum-latency schedules). Applying the Farkas Lemma to (4) and gathering/equating coefficients of the iterators and parameters yields linear equalities and inequalities entirely in the coefficients of the affine mappings for all statements and the components u and w. The combined ILP system (tiling legality constraints (2) plus the bounding constraints) is solved at once by finding the lexicographic minimal solution with u and w in the leading position:

```
minimize≺ { u₁, u₂, …, u_k, w, …, c₀'s, … }     (Equation 5)
```

Finding the lexicographic minimum is within reach of the Simplex algorithm and handled by Parametric Integer Programming (PIP) software. Since program parameters are large, their coefficients are minimized with highest priority. The solution gives a hyperplane for each statement; the trivial zero solution is avoided by a practical choice described next.

**Iteratively finding independent solutions.** Solving the ILP gives a single solution per statement. At least as many independent solutions (per statement) as the dimensionality of its domain are needed. Once a solution is found, the ILP is augmented with constraints enforcing linear independence with solutions already found, by constructing the orthogonal sub-space of the transformation rows found so far (H_S) and forcing a non-zero component in its complement H_S^⊥ for the next solution. [orthogonal-projection formula, Equation 6 — see source PDF] Linearly independent statement-wise hyperplanes are found iteratively until all dependences are satisfied, yielding maximal sets of fully permutable loops but with an optimization criterion (5) that goes beyond maximum degrees of parallelism.

**Outer space and inner time: communication and locality optimization unified.** The best possible solution to (5) has (u=0, w=0): a hyperplane with no dependence components along its normal — a fully parallel loop requiring no synchronization (outer parallel), or an inner parallel one if some dependences were removed previously. Thus, at each step of finding a new independent hyperplane, the method first finds all synchronization-free hyperplanes, followed by hyperplanes requiring constant boundary communication (u=0, w>0); in the worst case, a hyperplane with u>0, w≥0 giving long communication from non-constant dependences is found last. By minimizing φ(t)−φ(s) from outermost to innermost, dependence satisfaction is pushed to inner loops while ensuring the new loops have non-negative dependence components so they can be tiled for locality and pipelined parallelism. Using the outer loops as space and the rest as time minimizes communication in the processor space.

**Fusion.** Fusion across multiple weakly connected iteration spaces (e.g. producer–consumer loop sequences) is also enabled. Since the hyperplanes do not include coefficients for program parameters, a solution found corresponds to a fine-grained interleaving of different statement instances at that level.

## 4. More Design Considerations

This section discusses enhancements and practical choices for scalability.

### 4.1 Handling input dependences

Input dependences (RAR) need to be considered for optimization in many cases, since reuse can be exploited by minimizing them. Legality (ordering between dependent RAR iterations) need not be preserved, so legality constraints (2) are not added for them, but they are considered in the bounding objective (4). Because input dependences may have negative components in the transformed space, they must be bounded from both above and below: |φ_Sj(t) − φ_Si(s)| ≤ v(p) over the input-dependence polyhedron. [formal inequalities — see source PDF]

### 4.2 Avoiding combinatorial explosion

Two situations risk combinatorial explosion with the number of statements: (1) avoiding the trivial zero-vector solution to the hyperplanes, and (2) construction of the linearly independent sub-space for each statement's transformation. Removing the trivial zero solution per statement leads to a non-convex space (a union of many convex spaces each of which must be tried); similarly, the linearly independent sub-space construction has a product of choices across statements. Both difficulties are solved at once by only looking for non-negative transformation coefficients: then the zero solution is avoided with the constraint Σ cᵢ ≥ 1 for each statement. This mainly excludes transformations involving loop reversal, which in practice is not a concern. The current PLUTO implementation uses this choice and scales very well without loss of good transformations; exhaustively exploring all choices remains feasible up to around ten statements within tens of seconds.

## 5. Tiled Code Generation for Arbitrarily-Nested Loops under Statement-wise Transformations

This section describes how tiled code is generated from the transformations found. The polyhedral code generator **CLooG** is used: it scans a union of polyhedra, optionally under a new global lexicographic ordering specified through scattering functions. Scattering functions are specified statement-wise; their legality must be guaranteed by the specifier (here, the automatic transformation system). CLooG uses PolyLib (and the Chernikova algorithm) for its core operations and generates far more efficient code than older Fourier–Motzkin-based generators (e.g. Omega Codegen, LooPo's internal generator), with much lower code-generation time and memory use.

### 5.1 Tiling the transformed AST vs. tiling the scattering functions

The paper distinguishes between (1) modeling and enabling tiling through the transformation framework and (2) final generation of tiled code from the hyperplanes found. The framework models tiling by finding affine transformations that make rectangular tiling in the transformed space legal; the hyperplanes found form the new loop basis and carry properties (parallel, sequential, or part of a tilable band). Final tiled-loop generation can be done either directly through the polyhedral code generator in one pass, or as a post-pass on the AST after applying the transformation; each has merits and they can be combined. For transformations that lead to imperfectly nested code, polyhedral (one-pass) tiling is the natural way to obtain legal tiled code, since reasoning about the legality of syntactic tiling/unroll-jam on the target AST is hard once outside the polyhedral model. *(Figure 3 illustrates this on imperfectly nested 1-d Jacobi, where straightforward 2-d syntactic tiling would violate dependences. [code/matrices — see source PDF])*

### 5.2 Tiles under a transformation

The approach specifies a modified higher-dimensional domain and transformations for the tile-space loops in the transformed space. For a simple 2-d nest with iterators i, j and transformation c₁=i, c₂=i+j forming a permutable band (hence blockable into 2-d tiles), the domain supplied to the code generator is a higher-dimensional domain with tile-shape constraints (in the style of Ancourt and Irigoin), and the scatterings are duplicated for the tile space (denoted with a 'T' subscript). For example:

```
Domain:                          Scattering:
0 ≤ i ≤ N−1                      c1T = iT
0 ≤ j ≤ N−1                      c2T = iT + jT
0 ≤ i − 32·iT ≤ 31              c1 = i
0 ≤ (i+j) − 32·(iT+jT) ≤ 31     c2 = i + j
(c1T, c2T, c1, c2) ← scatter(iT, jT, i, j)
```

This seamlessly tiles across statements of arbitrary dimensionalities, irrespective of original nesting, as long as the c's have dependences in the forward direction (guaranteed and detected by the transformation framework).

**Algorithm 1 — Tiling for multiple statements under transformations.**
```
INPUT: statement-wise hyperplanes of a tilable band of width k (φ_S^i … φ_S^{i+k−1})
       expressed as affine functions of original iterators; original domains D_S; tile sizes τ.
1. Update the domains:
   for each statement S:
     for each hyperplane φ_S^j = f^j(i_S) + f0:
        increase domain dimensionality by creating "supernodes" for all original
        iterators appearing in φ_S^j (supernode iterators iT_S);
        add constraints:  τj·f^j(iT_S) ≤ f^j(i_S) + f0 ≤ τj·f^j(iT_S) + τj − 1
2. Update the transformation matrices:
   for each statement S:
     add k new rows at level i and as many columns as supernodes added;
     for each φ_S^j (j = i … i+k−1): add a supernode hyperplane φT_S^j = f^j(iT_S)
OUTPUT: updated domains D_S and transformations
```
The tile-space loops are referred to as *supernodes*.

**Theorem 1.** The set of scattering supernodes obtained from Algorithm 1 satisfies the tiling legality condition (2). Since the underlying φ's satisfy (2) and the supernodes step through an aggregation of parallel hyperplane instances, dependences remain forward for the supernode dimensions, for both intra- and inter-statement dependences. ∎

The same tiling hyperplanes can be used to tile multiple times (registers, L1, L2, parallelism), with legality guaranteed by the transformation framework; the scattering functions are duplicated per level. *(Worked examples in the source: 3-d tiles for LU decomposition (Figure 2), and imperfectly nested 1-d Jacobi requiring a relative shift and space-loop skewing. [code/matrices — see source PDF])*

### 5.3 Parallel code generation

Once Algorithm 1 is applied, outer- or inner-parallel loops can be marked parallel (e.g. with OpenMP pragmas). Unlike scheduling-based approaches, because tiling hyperplanes are found and the outer ones used as space, there may not be a single transformed-space loop satisfying all dependences; care is needed when space loops carry forward dependences (*doacross* loops). For pipelined parallel codes, the approach is:

**Algorithm 2 — Tiled pipelined parallel code generation.**
```
INPUT: after Algorithm 1, a set of k statement-wise supernodes of a tilable band (φT_S^1 … φT_S^k)
1. To extract m (< k) degrees of pipelined parallelism, for each statement S:
2.   perform the unimodular transformation on the scattering supernodes only:
        φT^1 → φT^1 + φT^2 + … + φT^{m+1}
3.   mark φT^2, …, φT^{m+1} as parallel
4.   leave φT^1, φT^{m+2}, …, φT^k as sequential
OUTPUT: updated transformation matrices/scatterings
```
The sum φT¹+φT²+…+φT^{p+1} satisfies all affine dependences satisfied by its terms, giving a legal wavefront (schedule) of tiles. Because the transformation is only on the tile space, it preserves tile shape (and the communication/locality benefits of the bounding optimization), and introduces very little additional code complexity (no modulos appear, due to unimodularity). *(Figure 4 shows a simple example with tiling hyperplanes (1,0) and (0,1) generating clean parallel code with a single barrier in the tile space.)*

### 5.4 Intra-tile reordering

Because the algorithm pushes parallel intra-tile loops inward rather than outward, vectorization by the native compiler can be hindered. As a post-process, the parallel loop within a tile is moved innermost and `ignore-dependence` pragmas are used to force vectorization. Similar reordering can improve spatial locality (not captured by the dependence-driven cost function). Tile shapes and the tile-space schedule are not altered by this post-processing.

## 6. Implementation

The framework is implemented in the tool **PLUTO**. The scanner, parser, and dependence tester are taken from the **LooPo** infrastructure; **PipLib 1.3.3** is used as the ILP solver and **CLooG 0.14.1** for code generation. The transformation framework takes polyhedral domains and dependence polyhedra from LooPo's dependence tester, computes transformations, and feeds them to CLooG; compilable OpenMP parallel code is produced after some post-processing. *(Figure 5 shows the full PLUTO source-to-source tool chain.)* An annotation-driven system (Norris et al.) is integrated to perform syntactic transformations (register tiling, unrolling, unroll/jam) on the CLooG output as a post-pass, with the loop choices specified by the transformation framework so legality is guaranteed.

## 7. Experimental Evaluation

**Comparison with previous approaches.** Direct comparison is difficult because most prior implementations are unavailable (except Griebl's), and many earlier studies were not end-to-end automatic. Two state-of-the-art research approaches are compared by forcing PLUTO to produce the transformations those approaches would generate (so they also benefit from CLooG and the tiled code-generation scheme): (1) Griebl's approach using Feautrier's schedules with Forward-Communication-Only allocations to enable time tiling ("Scheduling-based (time tiling)"), and (2) Lim/Lam's affine partitioning ("Affine partitioning (max degree parallelism, no cost function)").

**Experimental setup.** Results were obtained on a quad-core Intel Core 2 Quad Q6600 at 2.4 GHz, 32 KB L1 D-cache, 8 MB L2 (4 MB shared per core pair), 2 GB DDR2-667 RAM, Linux 2.6.22 (x86-64). ICC 10.0 compiled both base and transformed codes with "-fast -funroll-loops" (and -openmp for parallel code). PLUTO's transformation runs in a fraction of a second per benchmark; the entire source-to-source transformation takes no more than a few seconds. Tile sizes were set automatically with a rough model; all optimized code was obtained automatically in a turn-key fashion.

The paper reports results on several kernels:

- **Imperfectly nested 1-d Jacobi stencil** — single-core speedups of 4×–7× from locality enhancement; parallel speedups compared favorably against Lim/Lam and Griebl time tiling. Just space tiling (and icc's auto-parallelizer) exposes insufficient parallelism granularity. *(Figure 6.)*
- **2-d FDTD** (Finite Difference Time Domain) electromagnetic kernel — four statements (three 3-d, one 2-d) imperfectly nested; the framework finds three fully-permutable tiling hyperplanes (combining shifting, fusion, and time skewing). *(Figure 7, results in Figure 8; nx=ny=2000, tmax=500.)*
- **LU decomposition** — three tiling hyperplanes in a single permutable band; the lower-dimensional first statement is sunk into a 3-d fully permutable space, giving two degrees of pipelined parallelism. ICC cannot auto-parallelize this. *(Figure 10.)*
- **Matrix Vector Transpose (MVT)** — two matrix-vector transposes within an outer convergence loop; the cost-function bounding fuses the first MV with the permuted second MV (driving the inter-statement input dependence distance to zero), yielding one degree of pipelined parallelism and best-in-class performance for N=8000. *(Figures 11–12.)*
- **3-D Gauss-Seidel SOR** — all three dimensions tilable after skewing space by factors of one and two w.r.t. time; two degrees of pipelined parallelism possible (1-d is better in practice due to simpler code). ICC does not parallelize this. *(Figure 13.)*

### 7.1 Analysis

All experiments show very high speedups, for both single-thread and multicore parallel execution, significantly outperforming production compilers and state-of-the-art research approaches (speedups of roughly 2×–5× over previous automatic transformation approaches). Decoupling the optimization of tile shapes and sizes proved a practical and effective approach. Integration of empirical tile-size models and complementary syntactic transformations is in progress and expected to move performance closer to machine peak.

## 8. Related Work

Iteration-space tiling is a standard approach for aggregating loop iterations into atomically executed tiles, known to improve register reuse and locality and minimize communication. Prior tile-shape/size selection studies were restricted to very simple codes (single perfectly nested loops with uniform dependences, or fixed depth) and have not been extended to general cases. PLUTO's contribution is a practical cost function that works for the general case (any polyhedral program), keeping the problem linear so that the resulting sparse ILPs solve very quickly — a sweet spot between cost-function sophistication and scalability. The function does not optimize tile sizes, but the results show that decoupling tile-shape and tile-size optimization is effective.

Ahmed et al. were among the first to tile imperfectly nested loops (for sequential locality), but their heuristic appears not to scale. Automatic parallelization in the polyhedral model falls broadly into scheduling/allocation-based approaches (Feautrier; Darte and Vivien; Griebl) and partitioning-based approaches (Lim/Lam). Pure scheduling-based approaches target minimum-latency schedules or maximum fine-grained parallelism rather than tileability for coarse-grained parallelism with minimized communication; on modern architectures at least one level of coarse-grained parallelism (and locality) is desired. Griebl integrates locality and parallelism with space and time tiling by treating tiling as a post-processing step after a schedule is found, using FCO allocations to enable time tiling — but using schedules as loops is not best suited for communication/locality optimization or target-code simplicity. Lim and Lam identify communication-free space partitions and permutable time partitions to maximize parallelism degree and minimize synchronization order, but provide no cost metric to differentiate the many equivalent solutions, which differ greatly in performance.

PLUTO is closer to the partitioning-based class but is, to the authors' knowledge, the first to explicitly model tiling within a polyhedral transformation framework, enabling effective extraction of coarse-grained parallelism together with locality optimization, while still handling untilable or partially tilable codes and capturing traditional transformations. Semi-automatic/search-based frameworks (URUK/WRAP-IT by Cohen et al. and Girbal et al.) compose transformations specified manually by an expert; recent iterative polyhedral approaches do not include tiling in their search space. Code generation under multiple affine mappings was first addressed by Kelly et al., advanced by Quilleré et al. and Bastoul (CLooG); PLUTO's tiled code generation combines Ancourt and Irigoin's domain/tile-size specification with CLooG's scattering-function support. Parametric tiled code generation techniques (for single-statement domains) complement the system and are candidates for future integration.

## 9. Conclusions

The paper presents the design and implementation of a fully automatic polyhedral source-to-source optimizer that simultaneously optimizes sequences of arbitrarily nested loops for parallelism and locality, demonstrating the practicality and promise of automatic transformation in the polyhedral model beyond current production compilers. Implemented as a tool generating OpenMP parallel C code, it shows significantly higher single-core and multicore performance than production compilers and state-of-the-art research approaches, while leaving room for future iterative/empirical optimization and more sophisticated cost models. Because the framework operates entirely in the polyhedral abstraction, only the polyhedra extractor and dependence tester need adapting to support a different input language — making it applicable to very high-level or domain-specific languages for generating high-performance parallel code.

## 10. Availability

A beta release of the PLUTO system, including all codes used for experimental evaluation, is available at http://pluto-compiler.sourceforge.net.

## Acknowledgments

The authors thank Cédric Bastoul (Paris-Sud XI University) for CLooG; Martin Griebl and team (Universität Passau) for the LooPo infrastructure; the submission reviewers; and Alain Darte for feedback. Supported in part by U.S. National Science Foundation grants 0121676, 0121706, 0403342, 0508245, 0509442, 0509467, and 0541409.

## References

1. PLuTo: A polyhedral automatic parallelizer and locality optimizer for multicores. http://pluto-compiler.sourceforge.net
2. N. Ahmed, N. Mateev, and K. Pingali. Synthesizing transformations for locality enhancement of imperfectly-nested loops. Intl. J. of Parallel Programming, 29(5), Oct. 2001.
3. R. Allen and K. Kennedy. Automatic translation of Fortran programs to vector form. ACM TOPLAS, 9(4):491–542, 1987.
4. C. Ancourt and F. Irigoin. Scanning polyhedra with do loops. In ACM SIGPLAN PPoPP'91, pages 39–50, 1991.
5. R. Andonov, S. Balev, S. Rajopadhye, and N. Yanev. Optimal semi-oblique tiling. IEEE Trans. Par. & Dist. Sys., 14(9):944–960, 2003.
6. C. Bastoul. Code generation in the polyhedral model is easier than you think. In IEEE PACT'04, pages 7–16, Sept. 2004.
7. C. Bastoul and P. Feautrier. Improving data locality by chunking. In Intl. Conf. on Compiler Construction (ETAPS CC), pages 320–335, Warsaw, Apr. 2003.
8. U. Bondhugula, M. Baskaran, S. Krishnamoorthy, J. Ramanujam, A. Rountev, and P. Sadayappan. Affine transformations for communication minimal parallelization and locality optimization of arbitrarily-nested loop sequences. Technical Report OSU-CISRC-5/07-TR43, The Ohio State University, May 2007.
9. U. Bondhugula, M. Baskaran, S. Krishnamoorthy, J. Ramanujam, A. Rountev, and P. Sadayappan. Automatic transformations for communication-minimized parallelization and locality optimization in the polyhedral model. In Intl. Conf. on Compiler Construction (ETAPS CC), Apr. 2008.
10. U. Bondhugula, J. Ramanujam, and P. Sadayappan. Pluto: A practical and fully automatic polyhedral parallelizer and locality optimizer. Technical Report OSU-CISRC-10/07-TR70, The Ohio State University, Oct. 2007.
11. P. Boulet, A. Darte, T. Risset, and Y. Robert. (Pen)-ultimate tiling? Integration, the VLSI Journal, 17(1):33–51, 1994.
12. P. Boulet, A. Darte, G.-A. Silber, and F. Vivien. Loop parallelization algorithms: From parallelism extraction to code generation. Parallel Computing, 24(3–4):421–444, 1998.
13. CLooG: The Chunky Loop Generator. http://www.cloog.org
14. A. Cohen, S. Girbal, D. Parello, M. Sigler, O. Temam, and N. Vasilache. Facilitating the search for compositions of program transformations. In ACM ICS, pages 151–160, June 2005.
15. A. Darte, Y. Robert, and F. Vivien. Scheduling and Automatic Parallelization. Birkhäuser Boston, 2000.
16. A. Darte, G.-A. Silber, and F. Vivien. Combining retiming and scheduling techniques for loop parallelization and loop tiling. Parallel Processing Letters, 7(4):379–392, 1997.
17. A. Darte and F. Vivien. Optimal fine and medium grain parallelism detection in polyhedral reduced dependence graphs. Intl. J. Parallel Programming, 25(6):447–496, Dec. 1997.
18. P. Feautrier. Parametric integer programming. RAIRO Recherche Opérationnelle, 22(3):243–268, 1988.
19. P. Feautrier. Dataflow analysis of scalar and array references. Intl. J. of Parallel Programming, 20(1):23–53, Feb. 1991.
20. P. Feautrier. Some efficient solutions to the affine scheduling problem: I. one-dimensional time. Intl. J. of Parallel Programming, 21(5):313–348, 1992.
21. P. Feautrier. Some efficient solutions to the affine scheduling problem. Part II. multidimensional time. Intl. J. of Parallel Programming, 21(6):389–420, 1992.
22. S. Girbal, N. Vasilache, C. Bastoul, A. Cohen, D. Parello, M. Sigler, and O. Temam. Semi-automatic composition of loop transformations. Intl. J. of Parallel Programming, 34(3):261–317, June 2006.
23. G. Goumas, M. Athanasaki, and N. Koziris. Code Generation Methods for Tiling Transformations. J. of Information Science and Engineering, 18(5):667–691, Sep. 2002.
24. M. Griebl. Automatic Parallelization of Loop Programs for Distributed Memory Architectures. University of Passau, 2004. Habilitation thesis.
25. M. Griebl, C. Lengauer, and S. Wetzel. Code generation in the polytope model. In IEEE PACT, pages 106–111, 1998.
26. E. Hodzic and W. Shang. On time optimal supernode shape. IEEE Trans. Par. & Dist. Sys., 13(12):1220–1233, 2002.
27. K. Hogstedt, L. Carter, and J. Ferrante. Selecting tile shape for minimal execution time. In SPAA, pages 201–211, 1999.
28. F. Irigoin and R. Triolet. Supernode partitioning. In ACM SIGPLAN PoPL, pages 319–329, 1988.
29. S. Kamil, K. Datta, S. Williams, L. Oliker, J. Shalf, and K. Yelick. Implicit and explicit optimization for stencil computations. In ACM SIGPLAN Workshop on Memory Systems Performance and Correctness, 2006.
30. W. Kelly and W. Pugh. A unifying framework for iteration reordering transformations. Technical Report CS-TR-3430, University of Maryland, College Park, 1995.
31. W. Kelly, W. Pugh, and E. Rosser. Code generation for multiple mappings. In Intl. Symp. on the Frontiers of Massively Parallel Computation, pages 332–341, Feb. 1995.
32. D. Kim, L. Renganarayanan, M. Strout, and S. Rajopadhye. Multi-level tiling: 'm' for the price of one. In Supercomputing, 2007.
33. H. LeVerge. A note on Chernikova's algorithm. Technical Report Research report 635, IRISA, Feb. 1992.
34. W. Li and K. Pingali. A singular loop transformation framework based on non-singular matrices. Intl. J. of Parallel Programming, 22(2):183–205, 1994.
35. A. Lim, S. Liao, and M. Lam. Blocking and array contraction across arbitrarily nested loops using affine partitioning. In ACM SIGPLAN PPoPP, pages 103–112, 2001.
36. A. W. Lim, G. I. Cheong, and M. S. Lam. An affine partitioning algorithm to maximize parallelism and minimize communication. In ACM ICS, pages 228–237, 1999.
37. A. W. Lim and M. S. Lam. Maximizing parallelism and minimizing synchronization with affine partitions. Parallel Computing, 24(3-4):445–475, 1998.
38. The LooPo Project — Loop parallelization in the polytope model. http://www.fmi.uni-passau.de/loopo
39. B. Norris, A. Hartono, and W. Gropp. Annotations for performance and productivity. 2007. Preprint ANL/MCS-P1392-0107.
40. R. Penrose. A generalized inverse for matrices. Proceedings of the Cambridge Philosophical Society, 51:406–413, 1955.
41. PIP: The Parametric Integer Programming Library. http://www.piplib.org
42. PolyLib — A library of polyhedral functions. http://icps.u-strasbg.fr/polylib/
43. S. Pop, A. Cohen, C. Bastoul, S. Girbal, P. Jouvelot, G.-A. Silber, and N. Vasilache. GRAPHITE: Loop optimizations based on the polyhedral model for GCC. In Proc. of the 4th GCC Developer's Summit, Ottawa, June 2006.
44. L.-N. Pouchet, C. Bastoul, J. Cavazos, and A. Cohen. Iterative optimization in the polyhedral model: Part II, multidimensional time. In PLDI'08, Tucson, June 2008.
45. L.-N. Pouchet, C. Bastoul, A. Cohen, and N. Vasilache. Iterative optimization in the polyhedral model: Part I, one-dimensional time. In ACM CGO, Mar. 2007.
46. W. Pugh. The omega test: a fast and practical integer programming algorithm for dependence analysis. Communications of the ACM, 8:102–114, Aug. 1992.
47. F. Quilleré, S. V. Rajopadhye, and D. Wilde. Generation of efficient nested loops from polyhedra. Intl. J. of Parallel Programming, 28(5):469–498, 2000.
48. J. Ramanujam and P. Sadayappan. Tiling multidimensional iteration spaces for multicomputers. JPDC, 16(2):108–230, 1992.
49. L. Renganarayana, D. Kim, S. Rajopadhye, and M. M. Strout. Parameterized tiled loops for free. In PLDI, pages 405–414, 2007.
50. R. Schreiber and J. Dongarra. Automatic blocking of nested loops. Technical report, University of Tennessee, Knoxville, Aug. 1990.
51. A. Schrijver. Theory of Linear and Integer Programming. John Wiley & Sons, 1986.
52. Y. Song and Z. Li. New tiling techniques to improve cache temporal locality. In PLDI, pages 215–228, 1999.
53. N. Vasilache. Scalable Program Optimization Techniques in the Polyhedral Model. PhD thesis, Université de Paris-Sud, INRIA Futurs, Sept. 2007.
54. N. Vasilache, C. Bastoul, and A. Cohen. Polyhedral code generation in the real world. In Intl. Conf. on Compiler Construction (ETAPS CC), pages 185–201, Mar. 2006.
55. N. Vasilache, C. Bastoul, S. Girbal, and A. Cohen. Violated dependence analysis. In ACM ICS, June 2006.
56. R. Whaley, A. Petitet, and J. Dongarra. Automated Empirical Optimizations of Software and the ATLAS Project. Parallel Computing, 2000.
57. D. K. Wilde. A library for doing polyhedral operations. Technical Report RR-2157, IRISA, 1993.
58. M. Wolf and M. S. Lam. A data locality optimizing algorithm. In ACM SIGPLAN PLDI '91, pages 30–44, 1991.
59. M. Wolf and M. S. Lam. A loop transformation theory and an algorithm to maximize parallelism. IEEE Trans. Parallel Distrib. Syst., 2(4):452–471, 1991.
60. J. Xue. Communication-minimal tiling of uniform dependence loops. JPDC, 42(1):42–59, 1997.
61. J. Xue. Loop tiling for parallelism. Kluwer Academic Publishers, Norwell, MA, 2000.
62. Q. Yi, K. Kennedy, and V. Adve. Transforming complex loop nests for locality. J. of Supercomputing, 27(3):219–264, 2004.
63. K. Yotov, X. Li, G. Ren, M. Cibulskis, G. DeJong, M. Garzaran, D. A. Padua, K. Pingali, P. Stodghill, and P. Wu. A comparison of empirical and model-driven optimization. In PLDI'03, pages 63–76, 2003.

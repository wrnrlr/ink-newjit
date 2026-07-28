# Open questions

Design decisions that are blocked on a call, not on effort. Each has the work scoped
and the evidence gathered — what's missing is which way to go.

Raised 2026-07-28…30 during the ASR/perf work; `doc/changelog.md` has what shipped.

---

## 1. Runtime error locations — what do we pay for them?

`!type` still tells you nothing about where. Parse errors now carry `line:col` + a
caret at zero VM cost, but runtime errors can't reuse that trick: ink returns errors
as VALUES, so there is no single raise point — the error is minted deep in a primitive
and flows back through the dispatch loop like any other value.

Measured in ReleaseFast: the cheapest hook (`if (r == .err) vm.err_pc = …` in
`doApply`) costs **+3.7% on dot, +7.7% on fibonacci**. Rejected under the "don't make
the VM slower" rule; prototype reverted.

Options: (a) a comptime `-Ddebug-locs` flag — free in release, locations when you are
actually debugging; (b) accept the cost; (c) something cleverer. (a) looks right.
Whatever lands must not widen `V` — errors are minted constantly in dispatch.
Detail: `.plan/tasks.md` → "Runtime error locations".

## 2. Silent blanks — what replaces the two rejected mechanisms?

Reading an enclosing lambda's local yields a blank (lambdas don't capture), and it
flows on quietly; handed to an FFI call it becomes a null handle that no-ops. This
cost more debugging time than anything else this session — a GPU benchmark "ran" for
an hour while dispatching nothing.

Two fixes were built and backed out, both for good reasons:
- **Compile-time error** → 100% false positives across lib/. GPU kernel and shader
  bodies are ordinary lambdas to the compiler but are INLINED by dye, where enclosing
  locals ARE in scope; and lib/fbx.k mirrors a param into a same-named global on
  purpose (`target::target`). The compiler cannot tell host lambdas from shader ones.
- **A `GlobalCk` opcode** raising only on an actually-blank read → precise and free,
  but too specific to carry in the opcode set, and it leans on `.blank`, which is
  going away.

Open: once `.blank` becomes monadic `::`, is the answer to reject it at the point of
USE — FFI marshalling refusing it instead of coercing to a null handle? That would
also catch the sibling failure: GPU resources built outside `gpu.computeRun`, where
`gpu.buffer` returns handle 0 and every later dispatch silently does nothing.
Detail: `.plan/tasks.md` → "Diagnostics for silent blanks (DX)".

## 3. Multi-statement blocks vs dict syntax

`$[cond; a; [stmt;stmt]]` no longer misbehaves — `[…]` is dict syntax, so a branch
without `key:` is a parse error with a caret. But there is still no block form, so
multi-statement work in a `$[]` branch must become a helper function.

An nprog-like syntax conflicts with `[…]`. Open: a different bracket, a keyword form,
or leave it and keep the helper-function idiom?

## 4. Kernel dialect: multi-accumulator / vector loop state

The largest remaining ASR cost is the Linear GEMM (~104 ms of the encoder at T'=32).
The fix is standard — register blocking, a 4×4 micro-tile per thread — but it needs
several accumulators live across the K loop, and a fold in the kernel dialect carries
exactly one value. Sixteen separate folds re-read the operands and win nothing.

Open: add vector/tuple loop state to the dialect (`{[acc;k] …}/[vec; !n]`)? It
unblocks a plausible 2–4× on the encoder's dominant kernel, but nothing else needs it
today, so it may not justify the dialect complexity on its own.

## 5. Closures, or just faster projections?

`lib/nn.k` carries ~20 module-level mutable globals whose only job is to smuggle a
value into a lambda (`nnMvX`, `nnColW`, `nnNmu`, the `td*` block). That is the biggest
source of accidental state in the file, and it makes those functions non-reentrant.

But ink already HAS flat copy-by-value closures — `MakePartial`, i.e. projections —
and `nnMvd[W;k;x;]' !n` uses one in the same file. So before adding lexical capture to
the VM: **measure projection application against the global-smuggling idiom.** If they
are within noise this is a docs/idiom problem, not a VM one. If projections are slow
(e.g. allocating a partial per call site in a loop), specialising that is a smaller and
better-targeted change than closures.

## 6. `/` spacing asymmetry — permanent?

`\` and `'` no longer care about spacing; `/` still does, because ` / ` after a noun or
verb is a comment. So `f \ x` ≡ `f\x` but `f / x` ≢ `f/x`. This is inherited from k and
is probably right, but `/` is now the only spacing-sensitive glyph, which makes it the
thing people will trip on. Documented in AGENT.md. Open: live with it, or is there a
comment syntax that lets `/` join the rule?

---

# Research ideas

(none recorded yet — see `.plan/tasks.md` for planned work and `doc/research/` for
written-up investigations.)

# Refactor `lib/` onto progn + early return — handoff

**STATUS: `lib/` is done (2026-08-04).** 33 single-use helpers inlined across
11 modules — `svd` (1), `llm` (5), `uitest` (4), `dye` (3), `kk` (14),
`canvas` (5), `slug` (2), `regex` (3), `fft` (1), `image` (1), `fbx` (1) —
and every comment asserting the old constraint is gone. Behaviour-preserving:
`zig build test`, the ten acceptance scripts, the whole `kk*`/`spirv` suite,
`make ui-test` and `make ui-shot` (pixel-exact goldens) all byte-identical, and
`svd`/`canvas`/`fft`/`llm`/`image` were pinned against a reconstructed original
before/after. `make docs-api` shrank exactly where intended (`bmp.write` and
`image.write` are newly documented, having inherited their helper's comment).

Deliberately left alone, with reasons: `dye`'s ~35 `xLo*` per-op lowerers and
`spirv`'s `op*` stencils (uniform dispatch tables — the shape is worth more than
the line count; the stale comments were removed), `kk`'s `kkScan*Miss` trio
(passed as values to `kkScanPipe`, so they need names), and every recursive
driver and `f' items` each-helper (lambdas still don't close over parent scope —
*that* constraint has not gone away).

Two bugs this turned up are written up in `.plan/triage.md`: a **middle** elide
in `$[c; ; x]` is dropped rather than nulled, so the natural inverted guard
silently takes the wrong branch (use `$[~c; :x; ]`); and `lib/svd.k` is broken
today by the prelude migration (`sqrt+/x*x` is a seeded fold), unfixed here
because this refactor had to be behaviour-preserving and svd has no test.

Not covered: `demo/` and `tools/` still carry the old shape — `demo/edit.k`'s
`hlSync`/`hlBuild` and its whole named-op table are the obvious next batch (its
misleading comment is updated to say so).

---

Self-contained brief for a fresh agent session. The language change landed on
2026-08-03 (see `doc/changelog.md`, top entry). This task spends it.

Read first: the "Round brackets vs square brackets" and "Early return" sections
of `doc/reference.md`.

## The constraint that just went away

Until now a `$[…]` branch had to be a **single expression**. Anything with two
statements in it had to become its own top-level lambda — and because ink
lambdas do **not** close over the parent scope, that helper had to take every
value it needed as an explicit parameter. So one conditional arm cost a name, a
parameter list, and a call site.

Both halves of that are now unnecessary:

```k
/ before — a helper only because the branch could not hold two statements
svdRot:{[A;V;ik;z]
  r:svdJ[A@ik@0;A@ik@1;z]
  nc:svdR[r@0;r@1;A@ik@0;A@ik@1]
  (@[@[A;ik@0;:;nc@0];ik@1;:;nc@1]; …)}

/ after — a progn inlines it; `A`, `V`, `ik`, `z` are already in scope
$[cond; [r:svdJ[…]; nc:svdR[…]; (…)]; other]
```

A progn opens **no scope**: names it binds are locals of the enclosing lambda,
which is exactly why the parameter-passing disappears.

Early return removes the other shape — the nested `$[…]` staircase written only
to avoid re-testing:

```k
{[s;pat] $[(#pat)>#s; -1; llm.idxm[s;pat;#pat;#s]]}     / before
{[s;pat] $[(#pat)>#s; :-1; ]; llm.idxm[s;pat;#pat;#s]}  / after, guard-style
```

## Confirmed starting points

These carry a comment that names the limitation outright — each is a site the
author would have written differently:

| file | line | note |
|---|---|---|
| `lib/svd.k` | 63 | "Factored out of svdP because ink's `$[;;]` branches must be single expressions." |
| `lib/dye.k` | 411 | "constMiss emits+caches a miss (each `$[]` arm is one expression)." |
| `lib/dye.k` | 1936 | "Each `$[]` branch must be ONE expression, so the multi-statement arith/math folds…" |
| `lib/dye.k` | 2002 | "One helper per op (each `$[]` branch must be a single expression)." |
| `lib/llm.k` | 66 | "a helper keeps the search out of a `$[…]` branch" |
| `lib/llm.k` | 83 | "Split across helpers so no `$[…]` branch holds a bracketed statement block." |
| `lib/uitest.k` | 159, 168 | "helpers, not bracketed `$-branches`" |

Find the rest with:

```bash
grep -rniE 'single expression|\$-branch|one expression|bracketed statement|helper' --include='*.k' lib/
```

That grep is a seed, not the work list — most single-use helpers carry no
comment at all. The reliable signal is **a top-level lambda called from exactly
one `$[…]` branch whose parameters are all names already live at the call site.**

## What NOT to inline

Scope this deliberately; "it is a small lambda" is not a reason.

- **Anything called from more than one place.** Inlining duplicates it.
- **Recursive helpers.** They need a name.
- **Anything public.** `lib/*.k` is self-documenting: a top-level binding with a
  comment directly above it is part of the module's API and appears in
  `doc/api/<mod>.md`. Deleting one is an API break. Run `make docs-api` and read
  the diff — it should only shrink where you *intended* to remove a private
  helper. See the doc rules in CLAUDE.md.
- **Helpers that exist for testability**, i.e. something a `test/*.k` calls
  directly. Grep `test/` for the name first.
- **`lib/dye.k`'s per-op helpers**, most likely. They look like the biggest win
  (three separate comments!) but they are a dispatch table over SPIR-V ops; a
  uniform one-helper-per-op shape may be worth more than the line count. Judge
  it, and if you leave it, delete the stale comments so the next reader is not
  misled.

## Gotchas that will bite

1. **A progn does not open a scope.** Inlining `f:{[a;b] t:…}` puts `t` — and
   any name it binds — into the *enclosing* lambda's locals. If the enclosing
   lambda already uses that name, you have silently clobbered it. Rename on
   inline; do not assume the helper's parameter names are free.
2. **Early return returns from the enclosing lambda**, never from the progn or
   the `$[…]`. `{$[c; [a:1; :a]; 0]; 99}` returns `1`, not `99`.
3. **`:` in *value* position is still the verb.** A call argument or list element
   keeps the old reading — `@[v;`px;:;99.]` is unchanged and must not be
   "converted". Only a leading `:` in statement position (lambda body, progn,
   `$[]` branch) is a return.
4. **Lambdas cap at 8 parameters** (`MAX_ARGS`). Inlining reduces pressure here,
   which is a secondary win in `lib/dye.k` and `lib/kk.k`.
5. **`,/()` returns a unit, not an empty list**, and `(),x` still boxes to `L` —
   unrelated to this change but easy to trip over while moving fold code around.
6. Two `$[…]` arms that *look* duplicated often differ in one index. Diff them
   before merging.

## Acceptance

Behaviour-preserving. No test may change, and no output may change.

```bash
zig build test                                     # 211/211
for f in lib/stats.k test/doc.k test/color.k test/regex.k test/rope.k \
         test/tables.k test/syntax.k test/fbx.k test/usd.k test/detok.k; do
  ./zig-out/bin/ink $f; done
./zig-out/bin/ink test/ir.k                        # slow, ~60s
make docs-api                                      # diff must be intentional
```

`lib/svd.k`, `lib/dye.k` and `lib/llm.k` have thin direct coverage — `test/spirv.k`
and `test/kkgold.k` exercise dye, `test/llm.k` needs a network key. **Before
touching a file with no oracle, pin its current behaviour**: capture the output
of a representative call, refactor, then diff. Do not refactor dye.k on the
strength of "it still compiles".

## Also worth doing while here

`AGENT.md` and `.plan/*` were updated for the new syntax, but individual `lib/*.k`
comments still assert the old constraint (the table above is a list of them).
Every comment you invalidate by inlining should die with the helper — a stale
"each `$[]` arm is one expression" is worse than no comment, because it will send
the next reader back to writing helpers.

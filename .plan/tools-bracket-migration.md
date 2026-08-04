# Migrate the editor tooling to the new bracket syntax — handoff

Self-contained brief for a fresh agent session. The language change landed on
2026-08-03 (see `doc/changelog.md`, top entry); this is the downstream editor
work it left behind.

Read first: the "Round brackets vs square brackets" and "Early return" sections
of `doc/reference.md`, then the Language Gotchas in CLAUDE.md.

## What changed in the language

| old | new |
|---|---|
| `[a:1;b:2]` | `(a:1;b:2)` dict |
| `[[]a:1 2;b:3 4]` | `([]a:1 2;b:3 4)` table |
| `[[k:1 2]v:3 4]` | `([k:1 2]v:3 4)` keyed table |
| `[]` (empty dict) | `()!()` |
| — | `[a;b;c]` **progn**, a statement block yielding its last value |
| — | `:x` in statement position — early return from the enclosing lambda |

The `[[` and `[[]` lexer tokens are **gone** (they had to be, or `[[1;2];3]`
could not parse as a nested progn). Two new CST kinds exist: `progn` and `ret`.
`[` directly after a noun is still apply/index.

## State of the tree

`zig build`, `zig build test` (211/211), and the k suite are green. All 169 `.k`
files parse. `lib/syntax.k` (the pure-k highlighter) and `test/syntax.k` are
already migrated — 64/64.

**`tools/tree-sitter-ink` is DONE but UNCOMMITTED.** It is a git submodule
(`.gitmodules`), and its working tree holds modified `grammar.js`,
`queries/highlights.scm`, `test/corpus/dict.txt` and the regenerated `src/*`.
`tree-sitter generate` + `tree-sitter test` pass 72/72. Nothing else is migrated.

## Tasks

### 1. Publish the grammar and re-pin it

`tools/zed-ink/extension.toml` pins the grammar by commit:

```toml
[grammars.ink]
repository = "https://github.com/wrnrlr/tree-sitter-ink"
commit = "1dee96269fa38b63f0a285a4b1aa5addaf0ecb9c"
```

Commit and push the `tools/tree-sitter-ink` submodule, bump that `commit` to the
new hash, then bump the parent repo's submodule pointer. Zed builds the grammar
from this pin, **not** from `tools/zed-ink/grammars/`, so nothing an editor sees
changes until this is done.

### 2. Fix the Zed query files — these will hard-error

Zed extensions ship their own queries in `languages/<lang>/`, and these still
name deleted node types. A tree-sitter query naming a node type that no longer
exists fails the *whole file*, so ink highlighting in Zed breaks entirely rather
than degrading. (`tree-sitter test` reported exactly this: `Query error at
105:9. Invalid node type [[]`.)

- `tools/zed-ink/languages/ink/highlights.scm` **lines 102–108** — `(dict "["`,
  `(table "[[]"`, `(utable "[["`. Mirror the already-migrated
  `tools/tree-sitter-ink/queries/highlights.scm`, which is the reference: dict
  paints `(` `)`, table/utable paint `(` `[` `]` `)`, and a new rule paints
  `progn`'s brackets `@comment` like the other syntactic (non-literal) brackets.
- `tools/zed-ink/languages/ink/brackets.scm` **lines 9–12** — still declares
  `"[[]"` and `"[["` as multi-character openers. Both are gone; a plain `[`/`]`
  pair now covers progn, and `(`/`)` covers the literals.
- Check `languages/ink/{outline,locals,indents,runnables}.scm` too.
  `indents.scm` uses the wildcard forms `(_ "[" "]")` / `(_ "(" ")")`, which
  survive unchanged, but confirm the indent behaviour is still what you want now
  that a progn body is a `seq` rather than dict `items`.
- `languages/ink-repl/highlights.scm` — grep it for the removed node types.

### 3. Decide what `tools/zed-ink/grammars/` is for

It holds `ink/grammar.js` and `ink_repl/grammar.js`. The ink copy is **stale** —
it predates several upstream changes (`_blank_sym` external, the multi-line
`cond` rewrite, the quoted-symbol comment). Since `extension.toml` pins the
grammar repo by URL+commit, this looks like a build cache rather than a source
of truth. Confirm that, then either delete it or resync it wholesale. Do not
half-sync — a copy that is correct for brackets and stale everywhere else is
worse than an obviously stale one.

### 4. `tools/tree-sitter-ink-repl` — probably a no-op, verify it

Grepping it for `dict|table|args|'['` returns nothing, so it likely has no
bracket rules to migrate. Confirm, and confirm its Zed query file is clean. If
it is genuinely unaffected, say so in the commit message so the next person does
not re-check.

### 5. Audit `tools/lsp.k`

It reads CST kinds `lambda`, `bind`, `transit`, `apposit`, `term` — none removed
— so it should still run. Two things to actually check rather than assume:

- `topBinds` (line ~116) is `(kind=bind) & 0=parent`. A bind inside a progn now
  has a **progn** parent, not the root, so it is no longer a top-level symbol.
  That is almost certainly right, but decide deliberately whether a top-level
  `[a:1;b:2]` block should contribute document symbols.
- Hover/definition on a name bound inside a progn. A progn opens **no scope**, so
  those names are ordinary locals of the enclosing lambda — resolution should
  already work, but there is no test for it.

Add coverage either way. Then check `tools/klint.k` (the `<=`/`>=` linter) still
walks the tree.

### 6. `lib/doc.k`

`doc.KK` (line ~131) maps CST kinds to value types and has no `progn`/`ret`
entry, so a binding whose value is a progn (`f: [a;b]`) types as `expr`. Confirm
that is wanted. `make docs-api` currently regenerates cleanly and `make
docs-check` reports 5 modules with no documented API — that is the baseline;
neither number should move.

### 7. Stale reference in CLAUDE.md

The Useful References list names `tools/prosemirror-ink/`, which does not exist
in the tree. Either restore it or drop the line.

## Known non-regressions — do not chase these

`tree-sitter parse` over `lib/ demo/ test/` reports 6 failures. All 6 are
**pre-existing** and identical under the old grammar (verified by stashing the
grammar change and re-running):

- ERROR: `lib/fbx.k:246`, `lib/image.k:30`, `lib/usd.k:81`, `demo/clothbench.k:63`
- MISSING var: `demo/walk3.k:37`, `test/stencil.k:35`

The two MISSING ones are the `` `t@[] `` niladic-call idiom: the grammar's
`amend` rule is `S($.amend_op, I('['), $.seq, ']')` with a **required** seq, so
an empty `@[]` cannot parse. Optional easy win: make it `O($.seq)`. Note that
ink itself accepts `` `t@[] `` — `[]` there is an empty progn, i.e. null.

## Verification

```bash
cd tools/tree-sitter-ink && tree-sitter generate && tree-sitter test   # 72/72
tree-sitter parse -q --stat '../../lib/*.k' '../../demo/*.k' '../../test/*.k'
cd ../.. && zig build test && ./zig-out/bin/ink test/syntax.k          # 64/64
make docs-api && make docs-check
```

For the Zed side there is no headless check — install the extension locally and
open a migrated file with all three forms in it (`demo/recs.k` has a table *and*
a keyed table; `lib/spirv.k` has plain dicts) and confirm nothing is uncoloured.

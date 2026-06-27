---
name: k-parser-in-k
description: k parser written in k for the ink runtime — location, status, and key ink-specific gotchas
metadata:
  type: project
---

A working k parser in `test/parse.k` that parses k source strings and returns AST as nested k lists.

**Entry point:** `kparse "expr"` → `(`terse; stmts)` AST

**Why:** User asked for a self-hosted k parser using ink's runtime.

**How to apply:** Load with `\l test/parse.k`, then call `kparse "source string"`.

## Ink k gotchas discovered while writing this:

1. **Lambdas don't close over parent-function locals** — free vars resolve globally. Use `::` for global assignment from inside a function (`x:: val`, not `x: val`).

2. **Char equality: use `~` not `=`** — `c = "x"` gives `!type` on char type. Use `c~"x"` (match).

3. **No `>=` / `<=`** — `a>=b` parses as `a > (=b)` = `a > Group(b)`. Use `~(a<b)` instead.

4. **`$[]` treats every `;` as cond/body separator** — multi-statement branches (`r:expr; use_r`) silently break. The bind/assign expression as condition absorbs (or interferes with) the following body. Every complex branch must be a dedicated helper function.

5. **`&` chains need explicit parens** — `x<n & f[x]in S` parses as `x < (n & (f[x] in S))`. Write `(x<LxN) & (f[x]in S)`.

6. **`s@i` vs `s[i]` for `in` membership** — `s@i in Chars` parses as `s @ (i in Chars)` = wrong. Use bracket notation: `s[i] in Chars` parses as `(s[i]) in Chars` = correct.

7. **`&/bool_scalar` gives `!type`** — `&/1b` fails; `&/` only works on bool vectors. Use `(#ds)=#&(ds in Chars)` to check if all chars are in a set.

8. **Symbol names can't contain `_`** — `\`adverb_val` is lexed as `\`adverb` + `_` + `val`. Use `\`advval` etc.

9. **`TT[x;0]` gives `!rank` for list-of-lists** — use chained indexing `TT[x][0]` instead.

10. **`TV` substring: use `s@(start+!len)`** — returns 1-char strings when len=1 (type C not c). Compare with `(*TV[i])~";"` (not `TV[i]~";"`).

11. **`x@0+1` parses as `x@(0+1)`** — when using indexed state, write `(x@0)+1` not `x@0+1`.

12. **While loop `{pred} f/` with tuple state** — predicates like `{(x@0)<n}` work correctly. But if `f` uses `st@0+1` instead of `(st@0)+1`, position never advances.

## AST format:
- Nodes are nested k lists: `(`tag; child1; child2; ...)`
- Leaf nodes: `,`tag` (enlisted symbol, e.g. `,`op`, `,`int`)
- Separators: `\`sep` (bare symbol) and `\`div` (bare symbol) between statements/items
- String values in nodes (op chars, adverb chars) come from `TV[i]` = source slice

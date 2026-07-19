---
name: ink
description: Write, run, and debug programs in Ink (aka terse), a k-family array programming language similar to ngn/k and k9, with .k source files. Use when writing or modifying ink/k code, running ink scripts, using ink libraries (json, csv, http, llm, crypto, audio, image, font, gpu), or writing GPU compute/shader kernels in ink.
---

# Writing Ink

Ink is a k-family array language: polysemic operators (meaning depends on arity and type),
strict **right-to-left** evaluation, **no operator precedence** (`2*3+4` → `14`).
Source files use `.k`. Runtime is a bytecode VM written in Zig; a GPU compiler (dye)
turns ink lambdas into SPIR-V.

## Toolchain

- Binary: `ink` on PATH, else `~/.ink/ink` (override home with `$INK_HOME`).
  Libraries autoload from `$INK_HOME/lib` — public namespaced names like `json.parse`
  load their module on first use, no import needed.
- Evaluate an expression (auto-prints the result): `echo '1+2' | ink` → `3`.
  Use this constantly — test every non-trivial snippet in the pipe before putting it in a script.
- Run a script: `timeout 5 ink script.k` — **always use a timeout**; runaway loops are easy to write.
- Script top-level expressions do **not** auto-print. Print with `` `0 0: $expr ``
  (stringify + write line to stdout); raw text: `` `0:"hello" ``. (`"" 0: x` writes to a
  file named `""`, not stdout.)
- Script args bind to `x` (also `` `argv[] ``); environment: `` `env[] `` (a dict).
- `ink disasm script.k` prints bytecode; `ink bundle script.k` ships a self-contained executable.

## Crash course

```k
x: 42                 / assignment. `:` local (inside lambda) / global (top level)
y:: 7                 / `::` assigns a GLOBAL — required to set globals from inside a lambda
v: 1 2 3              / int vector (i32). 1.5 2.5 is f32. Mixed int/float join does NOT promote!
s: `a`b`c             / symbol vector.  "abc" char vector.  "a" is a char ATOM, not a string
d: [a:1;b:2]          / dict, same as `a`b!1 2.  d`b → 2  (parenthesize (d`b) if an operator follows!)
t: [[]n:`a`b;v:1 2]   / table (dict of columns);  +t flips table↔dict
f: {x+y}              / lambda, implicit params x y z;  {[a;b]a+b} explicit — MAX 8 params
f[1;2]                / bracket apply;  f[;2] fixes the FIRST arg (x), not the second!
$[c;t;e]              / cond (branches must be single expressions, use helper fns for blocks)
!5                    / iota → 0 1 2 3 4
#v  |v  *v  *|v       / count, reverse, first, last
&mask  =v  <v  >v     / where, group, grade-up, grade-down
?v  x?y               / distinct;  find (returns #x when NOT found, not 0N)
+/v  +\v              / fold (sum), scan;  |/ max, &/ min, */ product, ,/ raze
f'v   x f'y           / each;  zip (each-pair)
a f/: b   a f\: b     / eachright (fixed left arg), eachleft
x mod y   x div y     / the only 4 keyword verbs: in has mod div (ALL int-only except in/has)
sqrt 4 9              / math fns are prelude names: sqrt sqr exp log sin cos abs asin acos atan atan2
x: 5   / comment      / `/` is a comment ONLY when preceded by whitespace or at line start
```

## Rules that silently break code

1. **No `<=` `>=`.** `x<=y` parses as `x<(=y)` (group!). Write `~(x>y)` and `~(x<y)`.
2. **`_` is never part of a name** — it's always the Drop/Cut verb. `foo_bar` = `foo _ bar`. Use camelCase.
3. **Lambdas do NOT close over parent scope.** An inner lambda sees only its own params/locals
   and globals. Lift helpers to top level; thread fixed values with `a f/: b` (eachright) or
   partial `f[fixed]'list`.
4. **`'` binds to its LEFT:** `f g' x` is `(f g)' x`, never `f (g' x)`. Pre-compute each into a
   variable, then call: `r: g' x; f r`.
5. **`` dict`key `` before an operator misparses:** `` (d`k)*2 `` needs the parens — `` d`k*2 `` indexes
   d by `` `k*2 ``. Safe only standalone; better: read fields into locals first.
6. **No inline assignment inside an expression chain:** `(*s)%*|s:svd x` fails. Assign on its own
   statement first: `s:svd x; (*s)%*|s`.
7. **Numbers are i32/f32.** Int literals > 2^31 are parse errors; int multiply overflows to `0N`
   (add wraps). `%` divides floats fine; `mod`/`div` are int-only (`f mod 11.` → `!type`).
8. **Empty-list edge cases:** `,/()` returns a unit (use `$[#x;,/x;!0]`); `+/()` on an empty
   sliced list is `!type` — guard `$[0=#k;0.;+/...]`.
9. **A `/` glued to `}` `)` `]` is the over adverb, not a comment.** `{…}/ comment` silently
   derives a fold. Always put a space before an end-of-line `/` comment.
10. **Newlines are statement separators everywhere** — a multi-line dyadic chain re-parses as
    separate statements. Keep an expression on one line.
11. **`[name:v;…]` is always a dict literal**, never a let-block — including as a `$[...]` branch.
12. **Diagnostic:** getting a `` `! `` (dict/error) where you expected a vector almost always means
    a parse-binding gotcha (rules 4, 5, 9) — re-read the expression right-to-left.

## References (read on demand)

| file | read when |
|------|-----------|
| [references/language.md](references/language.md) | full verb/adverb/type/IO reference — writing anything beyond basics |
| [references/gotchas.md](references/gotchas.md) | code misbehaves, wrong types, silent failures, porting from k/q |
| [references/libraries.md](references/libraries.md) | json, csv, http, llm, crypto, compress, zip, image, audio, font, regex, parquet, safetensors |
| [references/gpu.md](references/gpu.md) | windows/drawing/meshes, GPU compute, the dye shader dialect |

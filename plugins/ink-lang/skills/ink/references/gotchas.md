# Ink Gotchas

Hard-won failure modes, grouped by category. Most fail **silently** (wrong type,
blank output, garbage value) rather than erroring. When a value has type `` `! ``
(dict/error) where you expected a vector, suspect a parse-binding gotcha.

## Parsing & precedence

- **No `<=`/`>=`.** `x<=y` parses as `x<(=y)` — monadic `=` is group. Use `~(x>y)`, `~(x<y)`.
  Also in symbol lists: `` `<`>`<= `` breaks — the lexer reads one glyph per backtick.
  Use explicit list form `(`<;`>;`=)` for operator-symbol lists.
- **`_` is always the Drop/Cut/Delete verb**, never a name char. `foo_bar` = `foo _ bar`.
  Underscore keys (e.g. `TEXCOORD_0`) are unwritable as literals — build at runtime:
  `` `s$"TEXCOORD_0" ``.
- **`'` (each) binds to its LEFT term:** `f g' x` = `(f g)' x`; `f {…}' !n` calls f with the
  lambda then eaches the result. Always pre-compute: `r:{…}' !n; f r`.
- **`verb ,/expr` misparses** — `,/` binds left. Parenthesize: `f (,/{…}'cs)`.
- **`` dict`key `` followed by an operator misparses:** `` d`k*2 `` = `d@(`k*2)`. Parenthesize
  `` (d`k)*2 `` or read fields into locals first. Same for `` (d`k)~val `` (match binds first).
- **`f 9: x` after a name is dyadic** — bracket the io verb: `f[9: x]`.
- **Comment `/` needs preceding whitespace.** `{…}/ (a;b)` is a FOLD derivation, not a
  comment — the value silently becomes garbage. Space before every EOL comment.
- **`-` gluing:** space before `-` + numeric literal = negative literal (`abs -4` → 4);
  glued `abs-4` = subtract; `abs -x` needs `abs[-x]`. `1 -2 3` is a 3-vector; `1-2` is `-1`.
- **Newlines are statement separators** — inside `{...}` a split dyadic chain becomes two
  statements (`A !\n B` makes `!` monadic). One expression = one line. Inside `(...)`
  `[...]` `$[...]`, newlines separate items like `;` (blank lines fine; only `;;` or a
  trailing `;` injects a null element).
- **`[name:v;…]` is ALWAYS a dict literal** — never a let-block, including inside `$[...]`
  branches. Refactor multi-binding branches into helper functions.
- **`1:path` inline as a call argument mis-parses** (`ParseJson 1:path` → `` `! ``). Assign
  first: `txt:1:path; json.parse txt`.
- **`$sym` keeps the backtick:** `` $`Foo `` → `` "`Foo" `` — strip with `` 1_$x ``.
  String→symbol is `` `s$"ab" `` (NOT `` `$ ``); single-char strings are atoms — enlist:
  `` `s$$[`c~@x;,x;x] ``.
- **Symbols end at operator glyphs:** `` `~ `` is null-symbol + match. Quote: `` `"+" ``, `` `"<=" ``.

## Scope & lambdas

- **No closures.** Inner lambdas see only their own params/locals and globals — never the
  enclosing lambda's. Fixes, in order of preference:
  1. `A f/: B` eachright with the fixed value as left arg: `mmul:{[A;B]A {+/x{x*y}'y}/: B}`
  2. Partial application: `f[fixed]'list` — `f[a]` fixes the FIRST param `x` (so put the
     fixed value first in the param list; `f[;a]` also fixes x, not y!)
  3. Lift helpers to global scope with a name prefix (`svdRot`, `svdD`, …).
- **`:` inside a lambda is local; `::` sets a global.** Forgetting `::` silently creates a
  dead local.
- **Max 8 params.** A 9th arg silently returns a projection instead of running — pack
  extras into a list/config vector.
- **Params can't be named `in has mod div`** (parse error). Prelude names (`count`, `first`, …) are fine.
- **While `f f/` only iterates if the body references `x`** — thread a counter, keep real
  state in globals.

## Numerics

- **i32/f32 only** (Tier 1). Literals > 2^31 → parse error. Int **multiply overflows to
  `0N`**, add **wraps**. Reconstruct i32 from LE bytes: `h:$[127<b3;b3-256;b3];
  b0+(256*b1)+(65536*b2)+16777216*h`.
- **Mixed int/float join does NOT promote:** `0,1,200.` → general list `(0;1;200.0)`, not
  `F`. FFI rejects it. Coerce: `(0.+a),(0.+b),c` or cast `` `f$ ``.
- **`mod`/`div` are int-only** — a float operand → `!type` that often collapses silently
  downstream. `` `f$(!n) mod k `` (mod first, cast after). `%` is float division.
- **f64/f16/u32 are isolated Tier-2 types** — suffix literals (`2.3d`), combine only with
  themselves; explicit cast to cross (`` `f$x ``, `` `d$x ``).

## Lists, dicts, empties

- **`,/()` → unit, not empty list.** Fold possibly-empty: `$[#x;,/x;!0]`.
- **`+/()` over an empty slice → `!type`.** Guard: `$[0=#k;0.;+/…]`.
- **`x,()` (right-empty) preserves type; `(),x` (left-empty) boxes to `` `L ``.** Use `!0`
  as an empty numeric seed, not `()`.
- **Fold state must be homogeneous.** `f/(,init),intseq` with mixed types → `!type`. Use
  N-do with a counter in the state: `(#seq) f/(state;seq;0)`.
- **`@[x;is;:;y]` sets every `is` position to the SAME y** (not elementwise). Row swap =
  two amends with saved temporaries.
- **`x?y` find returns `#x` when absent** (not `0N`) — enables the fallback idiom
  `(vals,fallback)@keys?query`.
- **`&` (where) needs a `` `B ``/`` `I `` vector**, not a general list of bools (which
  `~\:` returns). Build masks with plain `'` each; coerce with `0+mask`. Arithmetic on an
  eachleft/eachright result can hang — avoid `0+(x~\:y)`.
- **`flip(a;b)` on simple-vector pairs errors** — use monadic `+` to transpose/zip:
  `+(xs;ys)` or `xs,'ys`.
- **`f'table` doesn't iterate rows** — returns keyed garbage. Build row-dicts first:
  `r:{[t;i](+t)@i}[t;]; r'!n`.

## Scripts & IO

- **Top-level expressions don't print in script mode.** `` `0 0: $expr `` to print;
  `` `0:"text" `` for raw text. `"" 0: x` goes to a file named `""`.
- **Always run scripts under `timeout`** — `timeout 5 ink f.k; [ $? -eq 124 ] && echo timeout`.
- **Nested `2:` loads StackOverflow** — a lib must not load its own deps; callers load in order.
- `1:"file"` returns `` `C `` chars already — don't re-cast with `` `c$ `` (can corrupt).
  Bytes→ints: `` `i$chars ``.
- **`. x` unwraps single-key dicts** — beware when generically processing dict values.
- No CR literal in strings — build with `` `c$13 ``.

## Performance idioms

- `name[i]::v` amends a global in place, O(1) — use for hot loops instead of `x::x,v` (O(n²)).
- Prefer flat homogeneous columns (`F`/`I`/`S`) over lists-of-dicts (SoA, k-style).
- Group-as-hashtable: `=x` gives value→indices; grade `<x` then cut for sorted sweeps.
- Whole-array shifts beat per-element loops (e.g. neighbour search via shifted copies).

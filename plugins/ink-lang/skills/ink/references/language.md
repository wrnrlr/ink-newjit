# Ink Language Reference (condensed)

Evaluation is strictly **right-to-left**, no precedence. A verb with nouns on both
sides is dyadic (infix); with a noun only on its right, monadic (prefix).
`f g h x` = `f(g(h(x)))`. Bracket form `f[a;b]` disambiguates; `f[;b]` is a
projection fixing the FIRST arg.

## Types

Type of x: `@x`. Lowercase = atom, uppercase = vector.

| sym | type | literal | null | notes |
|-----|------|---------|------|-------|
| `b`/`B` | boolean | `0b 1b`, vector `0110b` | | |
| `i`/`I` | int i32 | `-2 0 1` | `0N` | inf `0W -0W` |
| `f`/`F` | float f32 | `0.1 2. -3.` | `0n` | inf `0w -0w` |
| `s`/`S` | symbol | `` `px ``, `` `a`b`c `` | `` ` `` | interned; quote glyphs: `` `"+" `` |
| `c`/`C` | char u8 | `"H"` atom, `"Hi"` vector | `" "` | single char is an ATOM |
| `L` | general list | `(0b;1;2.3;`c)` | `()` empty | heterogeneous |
| `m` | dict | `[a:1;b:2]` = `` `a`b!1 2 `` | `[]` | |
| `M` | table | `[[]a:1 2;b:3 4]` | | dict of columns; keyed: `[[k:…]v:…]` |
| `o`/`p`/`q` | lambda / projection / composition | `{x+y}` | | |

**Tier-2 explicit-precision types** (isolated — combine ONLY with themselves,
cross-tier arithmetic is `!type`; enter/leave via cast):
`u`/`U` u32 (`3u`, null `0Nu`), `d`/`D` f64 (`2.3d`, null `0nd`), `h`/`H` f16 (`2.3h`).
Cast: `` `d$x ``, `` `f$2.5d ``, `` `u$5 ``. Tier 1 (`b→i→f`) promotes implicitly as in classic k.

Errors: `!type` `!rank` `!domain` `!parse_error`. Empty typed vectors: `!0` (I), `0#0.0` (F), `` 0#` `` (S), `""` (C).

## Assignment & scope

- `n:e` — local inside a lambda; global (constant) at top level.
- `n::e` — global, from anywhere (required inside lambdas).
- `n+:e` — compound: `n:n+e`; `n,:e` appends. `name[i]::v` amends a global in place (O(1)).
- Assignment must be its own statement — never embed `x:val` mid-expression.

## Verbs (monadic / dyadic)

| glyph | monadic | dyadic |
|-------|---------|--------|
| `+` | flip (transpose) | add |
| `-` | negate | subtract |
| `*` | first | multiply |
| `%` | shape (APL rho) | divide (float ok) |
| `!` | `!i` iota; `!I` odometer; | `x!y` make dict |
| `&` | where (indices of 1s / repeat counts) | min / and |
| `\|` | reverse | max / or |
| `<` | grade up (sort indices) | less |
| `>` | grade down | greater |
| `=` | `=X` group (val→indices); `=i` identity matrix | equal (elementwise) |
| `~` | not | match (deep identity) |
| `,` | enlist | join lists; merge dicts (right wins) |
| `^` | null mask | `x^y` fill nulls; `X^y` without/remove |
| `#` | tally/count | `x#y` take/cycle; `I#y` reshape (`0N` = infer); `X#d` take keys |
| `_` | floor/lowercase | `i_Y` drop; `I_Y` cut at indices; `f_Y` weed out by mask; `X_i` delete at index; `X_d` drop keys |
| `$` | to string | `s$y` cast (`` `I$"-12" ``, `` `s$"ab" `` str→sym); `i$C` pad |
| `?` | `?X` distinct; `?i` i random floats | `x?y` find (→ `#x` if absent!); `i?x` roll/deal |
| `@` | type | index/apply: `x@y` |
| `.` | `.d` dict values; `.s` get global by symbol | deep index / apply-N |
| `:` | identity | return right side |

Keyword verbs (only these four): `x in y`, `x has y`, `x mod y`, `x div y` (mod/div int-only).

Prelude math names (nouns, not verbs — `abs -4` works, `abs-4` subtracts):
`sqrt sqr exp log sin cos abs asin acos atan atan2` and `first last count parse exec depth epoch`.
Any monadic primitive is callable as a symbol: `` `sin@x ``, `` `parse x ``.

## Amend / drill (bulk update)

- `@[x;i;f]` — apply f at indices: `@["ABC";1;_:]` → `"AbC"`
- `@[x;i;:;v]` — set. NOTE: `@[x;is;:;y]` sets ALL of `is` to the SAME `y`, not elementwise.
- `.[x;path;f]` / `.[x;path;:;v]` — deep amend: `.[("ab";"cd");1 0;:;"x"]` → `("ab";"xd")`
- `?[C;I;C]` — splice: `?["abcd";1 3;"xyz"]` → `"axyzd"`

## Adverbs `' / \ ': /: \:`

Polysemic on operand arity/type. Digram forms take 2 left args.

| form | name | example |
|------|------|---------|
| `f'` | each | `#'("abc";3 4 5 6)` → `3 4` |
| `x F'` | zip (each-pair) | `2 3#'"ab"` → `("aa";"bbb")` |
| `F/` | fold | `+/1 2 3` → `6` |
| `F\` | scan | `+\1 2 3` → `1 3 6` |
| `x F/` | seeded fold | `10+/1 2 3` → `16` |
| `i f/` | n-do | `5(2*)/1` → `32` |
| `f f/` | while | body MUST reference `x` or it runs once |
| `f/` | converge | `{1+1.0%x}/1` → φ |
| `C/` / `C\` | join / split | `","/("a";"b")` → `"a,b"` |
| `I/` / `I\` | decode / encode | `24 60 60/1 2 3` → `3723` |
| `i':` | window | `3':"abcdef"` → sliding windows |
| `i f':` | stencil | f over each window |
| `F':` | eachprior | `-':12 13 11` → deltas |
| `x F/:` | eachright | `1 2*/:3 4` → `(3 6;4 8)` — the closure substitute |
| `x F\:` | eachleft | `1 2*\:3 4` → `(3 4;6 8)` |

Fused folds (fast paths): `+/ */ |/ &/ ,/` (sum, product, max, min, raze).

## Conditionals

`$[cond;then;else]`, `$[c1;r1;c2;r2;else]`. Branches must be single expressions
(move multi-statement work into helper functions; `[a:1;…]` in a branch is a dict literal).

## IO verbs

- `<"path"` open file handle; `<":5001"` / `<"host:port"` open socket; `>h` close.
- `0:x` read lines; `x 0:y` write lines (`` `0 0:"Hi" `` → stdout; a path creates the file).
- `1:x` read bytes (returns `C`); `` 1:`stdin `` reads available stdin bytes; `x 1:y` write
  bytes (`` `stdout 1: s `` / `` `stderr 1: s `` — raw, no newline, flushed).
- `2:"lib/foo.k"` load code by path; `2:"foo"` resolves to `lib/foo.k`. Do NOT nest `2:`
  loads (StackOverflow) — the caller loads deps first.
- `9: x` place array on GPU → descriptor dict; `d 9: x` overwrite in place; `8: d` fetch
  back; `n 8: d` first n. After a name, `f 9: x` is DYADIC — bracket it.

## Special symbols & commands

- `` `argv[] `` args, `` `env[] `` env dict, `` `prng[] `` random, `` `exit@i ``,
  `` `dir p `` recursive file listing (juxtaposition, not `@`).
- `\d ns` open namespace (compile-time name mangling to `ns.member`); `\d ns a b` = only
  a,b public; bare `\d` back to global. `\l name` load `$INK_HOME/lib/<name>.k`.
- `\t:n expr` time n runs in ms.
- Comments: whitespace-preceded `/` to EOL; a line with only `/` opens a block comment
  closed by a line with only `\`.

## Tables

```k
t: [[]id:1 2 3; age:20 43 7]   / table = flipped dict of columns
t`age                          / column → 20 43 7
t@1                            / row as dict
+t                             / flip to dict-of-lists (and back)
kt: [[id:1 2]name:`a`b]        / keyed table; index by key
```

To map over rows: don't `f'table` (iterates wrong) — build rows first:
`r:{[t;i]$[(@t)~`m;(+t)@i;t@i]}[t;]; r'!count t`.

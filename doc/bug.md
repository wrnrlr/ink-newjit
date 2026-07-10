# Issues

## 1. Integer parsing/cast overflow returns `0N`

```k-repl
 `I$"10000000000"
0N
```

`I` is backed by `i32` (`src/noun/class.zig`), so any value above
`maxInt(i32)` overflows on parse/cast and yields `0N`. Not a discrete bug — a
consequence of the 32-bit integer width. The real fix is widening integers to
`i64`, a large change touching the whole `i`/`I` backing type. Documented until
then.

---

## 2. Long for-each is slow at extreme sizes

```
  \t {x*3}'!100000000
```

Not a crash. The per-element `'` loop is interpreted (not vectorized):
`{x*3}'!1e7` takes ~4.4s / 245 MB in Debug, so `!1e8` extrapolates to ~44s /
~2.4 GB and chokes `rlwrap`'s output buffering. Fixable by vectorizing
scalar-arithmetic lambdas under each, otherwise just a cost to be aware of.

---

## 3. Font: eager materialization is slow for huge multi-face CFF (Debug)

`ReadFont` materializes every table for every face up front, including the full
per-glyph `glyf` outline list and CFF `charStrings` (raw charstring bytes per
glyph). For a 10-face CJK CFF collection (`NotoSansCJK-Regular.ttc`, ~65k glyphs
× 10 faces) that is ~655k string allocations → ~47s in Debug (`test/font.k`'s
ttc assertion alone dominates the suite). Release is far faster (c_allocator).
Not a correctness bug — a consequence of the "read everything into k" design.
If it becomes painful, make `glyf`/`charStrings` lazy (return a thunk or keep
the file buffer + offsets and materialize a glyph on demand). The ttc test
could also point at a lighter collection.

---

## 4. Slab free-size fragility — `Rc` header must stay 16 bytes (design note)

Confirmed sound as built. The epoch stamp added for ECS change-detection was
**not** a new `Rc` field — it is packed into the existing flags word
(`meta: u32` in `src/noun/rc.zig`: low 8 bits = `ArrayFlags`, high 24 bits =
epoch), so the header stays exactly 16 bytes (four `u32`s).

Why 16 matters: `array.deinit` (`src/noun/array.zig`) frees
`data_offset + cap*@sizeOf(T)` rather than the exact size `init` allocated. The
slab (`src/noun/slab.zig`) requires the same size on alloc and free, so this
reconstruction is exact only when `data_offset` is a multiple of every element
size (1/2/4/8/16). `data_offset = @sizeOf(Rc) = 16` satisfies that for all
element types, so it is correct — but it relies on the header being 16.

Growing `Rc` to 20/24 bytes would make `data_offset` not a multiple of the
`V`/dict element size; `cap = (total-data_offset)/size` would floor away a
remainder and `deinit` would free fewer bytes than allocated → DebugAllocator
"alloc 64 / free 56" mismatch. So the 16-byte constraint is load-bearing.

To make the header growable later, `deinit` must free the *actual* allocated
size, not reconstruct it: `init` passes sizes >1024 through unchanged while
`initWithCap` uses `ceilPowerOfTwo` for >1024, so `deinit` can't blindly
re-round — it must store the size class in the header or unify the two rounding
paths. Not blocking; the 16-byte constraint is fine. Documented so the next
header change doesn't rediscover this the hard way.

---

## 5. Concatenating a typed vector with `()` upcasts it to a boxed `` `L ``

```k-repl
 (`a`b),()
(`a;`b)                 / `L (boxed general list), not `a`b (`S)
 ((`a`b),())!1 2
 ... lookup by `a fails ...
```

`x,()` should be identity (append nothing), but joining a typed vector
(symbol vector `` `S ``, int vector `` `I ``, …) with the empty general list `()`
re-types the result to a boxed general list `` `L ``. Two downstream surprises:

- A dict built from such keys no longer matches plain-symbol lookups:
  `((`a`b),())!1 2` indexed by `` `a `` returns empty (the keys are boxed
  symbols, not a `` `S `` vector).
- `,/sections` where one branch is `()` (e.g. an `$[cond; vec; ()]`) boxes the
  whole razed result to `` `L ``.

Found while building `lib/spirv.k`'s `VertexShaderU`: a `(keys,())!(vals,())`
env-merge silently lost every binding, and an assembly section list with an
empty branch produced a `` `L `` SPIR-V word list that the GPU host's `kip()`
then rejected (a uniform mesh pipeline silently failed → black screen, no
error). Worked around by guarding the empty case
(`$[n>0; (a,b)!(c,d); a!c]`) and using `!0` (empty `` `I ``) rather than `()`
for empty integer sections. The clean fix is for dyadic `,` (Join) to treat an
empty operand as identity and preserve the non-empty operand's type
(`src/primitive/verb/` join path). Related to the general-list dict-join issue
already noted for `lib/recs.k`.

---

## 6. List *literal* caps at 255 elements (`MakeList` count is `u8`)

A list literal / collection passed in one expression (e.g. `+/(a0;a1;…;a999)`)
lowers to a `MakeList` whose element-count arg is a single byte, so >255 elements
panic at compile (`compiler.zig` `lowerInst`, `@intCast(inst.arg1)` to `u8`).
Surfaced while stress-testing the (now-fixed) global limit. Same shape as the old
256-global issue: widen the `MakeList` count if it ever bites in practice (build the
list incrementally / via `,/` over chunks as a workaround). Low priority — literals
that large are rare.

---

## 7. `walk.k` value-iteration amend returns `!type` (pre-existing)

`test/walk.k` section 2 (the plain N×N relaxation) errors:

```k
N:100;(r;c):1+!2#N-2;I:c+N*r;W:((-N),N,1,-1)+/:I
f:{@[x;I;:;1.+.25*+/x@W]}
f (N*N)#0.0        / → !type
```

`W` builds fine (`#W` ok); the fault is inside `f` — the amend
`@[x;I;:;1.+.25*+/x@W]` (index-list gather `x@W`, reduce, then amend-assign back
at indices `I`). Present in both the scalar and SIMD builds, so unrelated to the
SIMD kernels. Sections 1 (random walk) and 3 (D4-symmetric iteration) run fine.
Not yet triaged — likely the `@[x;idxvec;:;computed-vec]` amend path or the
`x@W`/`+/:` gather over a matrix of indices.

---

## 8. `` `~ `` (and other op-glyph symbols) glue to a following backtick — Match needs spaces

```k-repl
 `~`          / → `~`   (the SYMBOL "~", then a null symbol — NOT a match)
 ` ~ `        / → 1b    (Match of two null symbols, as intended)
```

The lexer greedily consumes op-chars into a backtick symbol (`` `<= `` is the
symbol `<=`, by design), so `` `~` `` reads as `` `~ `` (symbol "~") followed by
`` ` `` (null symbol), i.e. a juxtaposition/index — never the dyadic Match verb
`~` between two `` ` `` operands. To use a verb glyph as a verb next to a symbol
literal, surround it with spaces: `` ` ~ ` ``, `` ` = ` ``, etc. Surprising for
the common `x~y` idiom when `x`/`y` are backtick symbols; the greedy-symbol rule
is otherwise intentional (see AGENT.md "Multi-char operator symbols"). Cost real
time while writing `lib`/`tools/lsp.k` (a `` `~w `` blank-check silently misread).

---

## 9. Special-symbol builtins apply by juxtaposition / brackets, not `@`

```k-repl
 `dir "lib"     / → recursive file list (works)
 `dir["lib"]    / → same (works)
 `dir@"lib"     / → !  (does NOT route to the builtin)
 `argv@0        / → (blank)  — same problem
 `asin@0.5      / → 0.523…   — but THIS one works via @
```

A bare `` `sym `` (e.g. `` `argv ``, `` `env ``, `` `dir ``, `` `x ``) is a
special-form builtin (`src/runtime/syms.zig`). Applying it with juxtaposition
(`` `dir p ``) or brackets (`` `dir[p] ``) routes to `syms.apply`; applying it
with `@` does **not** for these (even though `Apply`'s `_s_*` cases point at
`applySymFn`). Only the inverse-trig helpers (`` `asin@x ``, `` `atan2@(y;x) ``)
work through `@`, which is inconsistent with how they're documented. Either `@`
should route all symbol-applies, or the trig docs should show juxtaposition.

---

## 10. Namespace member forward-reference resolves to blank under script eval

Inside a `\d ns` block, a member that references another member defined *later*
in the same file compiles to a blank when the file is evaluated statement-by-
statement (`ink file.k`, evalStream) — the call silently no-ops (no reply / wrong
value). The same file loaded via the autoloader (`vm.load`, whole-file compile)
resolves the forward ref fine. Order definitions so every member precedes its
first use, or the compiler should defer global-name resolution to call time.
(Hit in `tools/lsp.k`: `onDef` → `defBuiltin` defined later → definition-on-
operator returned nothing until reordered.)

---

## 11. `parse` of many files leaks IR-lowering scratch (Debug allocator)

Running the k language server (`tools/lsp.k`), which `parse`s every workspace
`.k` file to build a cross-file index, ends with a DebugAllocator leak report at
`src/compiler/compiler.zig:1025` (`lower`, the `offsets = alloc.alloc(usize, …)`
scratch). A single `parse` does not leak; it accumulates over many parses. Debug-
only (release uses `c_allocator`), so no functional impact, but the lowering
scratch for `parse`'d chunks isn't freed. Low priority.

---

## 12. Raw byte write (`1:`) rejects a single-char atom

```k-repl
 `stdout 1: "ab"      / writes the 2 bytes
 `stdout 1: "a"       / -> !type   ("a" is a char ATOM, not a `C` vector)
 `stdout 1: ,"a"      / workaround: enlist to a 1-char `C` vector
```

The `1:` WriteBytes verb only dispatches on `C` (char vector) for the raw-write
paths (`_s_C`/`_C_C`/`_i_C` in `src/primitive/verb/io.zig`), so writing a single
character — which lexes as a char atom `c`, not `C` (single-char string is an
atom) — is a `!type`. Applies to the stdio handles (`` `stdout ``/`` `stderr ``),
files, and sockets. Harmless for the LSP (frames are multi-char) but surprising;
the fix is to accept a `c` atom as a 1-byte write in the byte-IO dispatch.
Workaround: enlist with `,`.

---

## 13. `2:"file"; expr` on one line panics (stack underflow)

```k
 2:"lib/regex.k"; regex.test[regex.compile["x"];"x"]   / → panic: integer overflow in vm.pop
 2:"lib/regex.k"                                        / fine (alone)
```
```k
 2:"lib/regex.k"
 regex.test[regex.compile["x"];"x"]                     / fine (newline-separated)
```

A `2:` load followed by `;` and another statement on the **same line** panics
(`src/runtime/vm.zig:738` `pop`, `stack_len -= 1` underflow) — the load's result
isn't balanced on the stack when the next statement is compiled in the same
chunk. Newline-separating the statements, or loading alone, works. Pre-existing
(reproduces reading from disk, unrelated to the embedded-module overlay);
surfaced while testing embedded `2:"lib/x.k"` loads. Same family as the earlier
nested-`2:` / `z:2:"f"` issues.

---

## 14. A keyword-verb param name is silently mishandled (dropped / mis-parsed)

```k-repl
 {[count;buf] count,buf}[100;3]      / → a DICT (`!), not `100 3`
 {[in;x] in,x}[1;2]                  / `in` dropped: arg mapping shifts
```

A lambda parameter named the same as a keyword verb (`in count first last has
mod div sqrt sqr exp log sin cos abs parse exec depth epoch …`) is not treated as
a plain local: the reference lexes as the *verb*, so `count,buf` parses as the
`count` verb applied (yielding a dict) rather than "join the two params", and
`in` is dropped from the parameter list entirely (shifting every later param /
the arg→slot mapping). No error — just wrong values. Cost real time twice: an
`in`-named kernel param in `lib/spirv.k`'s GpKernel silently shifted its env, and
a `count`-named param in `lib/instancing.k`'s `DrawResident` built a dict instead
of the `(count,buf)` vector the FFI expected (→ a no-op draw / black screen). Fix:
either reject keyword names for params at parse time, or bind params before verb
lookup. Workaround: never name a param after a keyword verb (use `cnt`, `src`, …).

---

## 15. `f +x` (function juxtaposed with a monadic-verb-prefixed arg) parses `+` as dyadic

```k-repl
 tcol:+(nTris;3)#triIds; av:triArea tcol     / correct: av = per-triangle areas
 av:triArea +(nTris;3)#triIds                / WRONG: parses as (triArea + reshape)
```

`triArea +x` is read as the dyadic add `triArea + x` (function plus matrix), not
`triArea (+x)` (apply `triArea` to the transpose `+x`). The result silently
collapses (adding a lambda to a matrix yields a 1-element/garbage value), so a
downstream table/`#` looks fine structurally but has 1 row. Any `f <op>x` where
`<op>` is meant monadically (`+`transpose, `-`negate, `|`…) next to an applied
function hits this; parenthesise the operand (`f (+x)`) or bind it to a temp
first. Cost time in `test/clothbench.k`'s CPU cloth setup (areas → inverse masses
collapsed → empty constraint tables → the whole solver silently did nothing).

---

## 16. Indexed-amend `x[i]:v` inside a lambda breaks the global (needs `::` / `@[]`)

```k-repl
 gIm::(400)#1.
 f:{[] gIm[0,19]:0.}   f[]   /  #gIm → 1  (gIm clobbered; single `:` makes a broken local)
 f2:{[] gIm[0,19]::0.} f2[]  /  #gIm → 1  (the `x[i]::v` deep-assign also collapses on a multi-index)
 f3:{[] gIm::@[gIm;0,19;:;0.]} f3[]  / correct: #gIm → 400, indices 0 & 19 zeroed
```

The `x[idx]:v` amend sugar amends the global correctly at top level, but inside a
function the single-colon form creates a broken local (`#gIm`→1, subsequent reads
error), and even the `::` deep-indexed-assign collapses when `idx` is a
multi-element index list. The reliable form inside a function is the explicit
amend `x::@[x;idx;:;v]`. Surfaced pinning corner masses (`gIm[0,nCols-1]:0.` /
`im0[0,W-1]:0.`) in `test/clothbench.k`'s size-parameterised setup functions —
the pins silently corrupted the mass array. Same family as the "`::` for globals
in lambdas" note, but specific to the *indexed* amend with a list index.

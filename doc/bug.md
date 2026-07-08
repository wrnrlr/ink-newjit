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

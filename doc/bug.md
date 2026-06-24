# Issues

## Recently fixed

- **`$0W` displays wrong / fails to parse.** `parseIntLit` had no `0W`/`-0W`
  case (it threw `InvalidCharacter`) and the formatter never mapped
  `maxInt(i32)`→`0W`. Both added, mirroring the float `0w`/`-0w` handling
  (`src/parser/parser.zig`, `src/noun/format.zig`).
- **Index-assign `d[`k]:v` crashed (stack underflow).** Indexed-lvalue
  assignment was never lowered. It is now desugared in `compileBind`
  (`src/runtime/compiler.zig`) as amend: `d[i]:v` → `d:@[d;i;:;v]`,
  `d[i]+:v` → `d:@[d;i;+;v]`, `d[i;j]:v` → `d:.[d;(i;j);:;v]`. Works for
  dicts (adds/replaces a key), lists and vectors.
- **DebugAllocator alignment mismatch building list values / compiling
  shaders / mapping a projection that captures a heap array** (was three
  separate reports). Single root cause: `FnTables` froze the raw backing
  allocator at construction (before `vm.alloc` was switched to the slab), then
  freed the derived bases — which are slab-allocated runtime values — through
  the raw allocator. `FnTables` now frees derived bases via a `value_alloc`
  pointed at the slab (`src/runtime/fntable.zig`, `src/runtime/vm.zig`), the
  same allocator that frees globals and the stack.

---

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

## 4. `klp` (FFI list-element pointer) is stubbed; `k_list_get` added instead

`src/ffi.zig` `klp` returns null ("not supported"). The font CFF-outline FFI
needs to read list elements (the global/local subr lists), so a
`k_list_get(list, index) → ref'd KBox` export was appended to `KRegistry`
(after `k_make_dict`, so existing extensions' shorter mirrors stay aligned).
`klp` could now either be implemented properly or removed in favour of
`k_list_get`. If you add fields to `KRegistry`, keep appending at the end and
update the mirror in `lib/font/kbuild.zig`.

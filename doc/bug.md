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
- **`klp`/`kbuild` duplication — k-ABI unified into a single source of truth.**
  Every native extension used to hand-maintain a copy of the host's `KRegistry`
  layout (`lib/font/kbuild.zig` `Registry`, the inline structs in md5/json/csv),
  which could silently drift from `src/ffi.zig`. The canonical layout now lives
  in `src/kabi.zig` as a single generic `KRegistry(comptime KH)` — the host
  instantiates it with its concrete `*KBox`, extensions with an opaque
  `*anyopaque` (identical `extern`/C layout, since a K handle is just a nullable
  pointer). `src/ffi.zig` and `lib/font/kbuild.zig` both import it (the latter
  via the `kabi` build module wired in `build.zig`), so the font mirror is gone.
  `klp` is kept as a null stub (superseded by `k_list_get`): removing it would
  shift every following field's offset and break already-built extensions, so
  the append-only ABI rule is documented in `kabi.zig`. (`include/k.h` remains
  the matching mirror for C-language extensions; md5/json/csv still carry inline
  prefix mirrors and can migrate to the `kabi` module the same way when touched.)
- **`table , dict` (Insert) leaked on shape mismatch.** When the row dict didn't
  conform to the table's columns, `insert.zig` returned `!length` but leaked the
  partially-built `new_data` array (the columns already appended plus the `N(V)`
  shell). The error path now `new_data.deinit`s before returning
  (`src/primitive/verb/insert.zig`). (There is still no table-aware *column*
  merge — `M,m` is row-insert only — but `dict , dict` column-merge works, so
  dict-of-columns archetypes don't need it.)
- **`,fn` (enlist of a function) corrupted the function.** Fixed in
  `src/primitive/verb/enlist.zig`: the `Enlist` monadic jump-table was missing
  the `_o` (lambda) and `_x` (object) signature fields, so enlisting fell through
  to `typeError1`. Now `@,f` → `` `L `` and the element stays callable
  (`((,f)@0) 5` and `5 {[a;s]s a}/,f` both work). `lib/ecs.k`'s `ecsRun` keeps its
  bare-or-list dispatch (`$[(@systems)~`func; …]`) — that is an ergonomic API
  used by `worldApply`/`worldQuery`/tests, not a bug workaround; the comments and
  `doc/ecs.md` no longer warn against `,sysMove`.
- **A `[...]` block (or any stray closer) as a `$[...]` branch hung the parser.**
  `parseCond` and `parseSeq` call `parseStmt`, which yields a `.blank` *without
  consuming a token* on something it can't start a statement from (a stray `)`,
  `}`, or a `[...]` block left mid-stream). The loops only terminate on their end
  token or eof, so they spun forever (`$[1; ); 0]`, `$[1)`, `(])`, …, and the
  `$[e=old; skip; [rebuild; stamp]]` case from `test/ecs_demo.k`). Both loops now
  break on no forward progress (token start unchanged after `parseStmt`)
  (`src/parser/parser.zig`). Malformed input terminates instead of hanging;
  valid `$[]`/list parsing is unaffected.
- **DebugAllocator "alignment 4 vs 8" on a compiled symbol-vector literal**
  (`test/ecs_query.k`, teardown only). The main chunk and compiler were created
  with the raw backing allocator before the `vm.alloc → slab` swap, but their
  literal constants are freed via the slab at teardown — alloc raw (align 4) /
  free slab (align 8). `VM.create` now builds the chunk and compiler *after* the
  slab swap (`src/runtime/vm.zig`), same principle as the `FnTables` fix. Verified
  clean: all ECS tests run with 0 alignment/leak errors.

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

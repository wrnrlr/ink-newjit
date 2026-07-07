# Issues

## Recently fixed

- **256-global ceiling raised to 4096 (global index widened `u8`→`u16`).** Was
  issue #6: the VM stored globals in `[256]V` and the bytecode encoded a global
  index in one byte, so the 257th distinct global name paniced at compile
  (`getOrAddGlobal`). Widened the index to `u16` end-to-end:
  `globals: [MAX_GLOBALS=4096]V` and `names: StringHashMap(u16)`
  (`src/runtime/vm.zig`); `getOrAddGlobal`→`u16` and `globals` map →`u16`
  (`compiler.zig`); `.Global`/`.AssignGlobal` now emit/skip a 2-byte arg in
  `lowerInst`, `instSize`, the VM decoders, `tape.zig instrSize`, and `disasm.zig`;
  list-assign target indices are 2 bytes for the GLOBAL form (`.Nop arg3==2`,
  `ListAssignGlobal` size `2+2n`) but stay 1 byte for the LOCAL form
  (`.Nop arg3==1`, locals are still `u8` — per-frame, 256 is plenty). The
  `.Nop` list-assign marker had to be split (it was shared by local + global
  list-assigns). Verified: all unit tests pass, 1000 globals works, global and
  local `(a;b;c):v` both work, all GPU demos unaffected. (Unrelated pre-existing
  limit still open: a list *literal* caps at 255 elements — `MakeList` count is
  `u8`.) The instancing/lib globals are still kept lean (opt-in `lib/instancing.k`)
  out of good hygiene, but no longer forced by the ceiling.

- **Arithmetic/`&` on a 1-element general list hung; `~\:`/`/:` left `` `L ``.**
  Two issues under bug #5. (1) `dyadContainerKernel`'s broadcast path
  (`src/primitive/verb/helper.zig`) used `x.ref()`/`y.ref()` to broadcast a
  count-1 operand — for a length-1 *list* that re-fed the whole list back into
  `dispatch2`, re-entering the same kernel forever (`0+,,1b`, `0+((,`G)~\:`G)`
  hung). It now broadcasts via `.at(0)`, which extracts the element from a
  length-1 container and returns the atom itself for a true atom. (2) `eachleft`
  /`eachright` (`src/primitive/adverb/eachside.zig`) returned `.{ .L = res }`
  raw while `each` calls `promote`, so `(,`G)~\:`G` came out as a `` `L `` of a
  bool atom (typing as `` `L ``, rejected by `&` with `!type`) instead of a
  clean `` `B ``. Both now `promote`, so `~\:`/`/:` yield typed vectors like
  `'` does. `lib/fbx.k`'s `\:` mask workaround (using plain `'`) is no longer
  needed.
- **While (`(cond)f/init`) ran once when the body ignored `x`.** An implicit
  lambda that references no argument infers `arity() == 0` (`compiler.zig`
  `Scope.arity`). `derived3`'s while-form guard (`src/primitive/derived.zig`)
  required `x.arity() >= 1` on the *step*, so an arity-0 body fell through to
  `fold` and iterated once. The while form is selected by the *left* operand
  being a function (cond); the step's arity is irrelevant — a body that loops
  via side effects (`{g::g+1;0}`) is a valid arity-0 step. Guard relaxed to
  `y.tag() == .o or .p` for both `/` (whiledo) and `\\` (whilescan). The
  arity-0 arg is freed safely by the Return-frame cleanup. `lib/fbx.k`'s
  step-counter workaround (threading `{…;x+1}`) is no longer required.
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

## 7. (FIXED) Empty vectors lost their type → `=`/`&` on them gave `!type`

Symptom: filtering an empty events table (`E@&`kind=E`kind` on an idle frame)
raised `!type`. Two root causes, both about *making* a typed empty — the
comparison kernels themselves were fine on genuine typed empties:

1. **`take` on a symbol/char/bool ATOM was unimplemented** — `` 0#`x ``,
   `0#" "`, `0#0b` all gave `!type` (only `_i_i`/`_i_f` existed), so you couldn't
   even write an empty `` `S ``/`` `C ``/`` `B ``. Fixed by adding
   `takeScalarAtom(.s/.c/.b)` to `src/primitive/verb/take.zig` (`n#atom` → n
   copies; `0#atom` → typed empty).
2. **A 0-row table/vector select degraded columns to untyped `` `L ``** —
   `pickVec`/`pickMask` built an `N(V)` and `promote`d it, but `promote` of an
   empty list can't infer a type → returns `` `L ``, and then `=`/`&` on `` `L ``
   fail. Fixed with `promote.emptyOf(k)` (typed empty of a class), returned by
   `pickVec`/`pickMask` when the selection is empty (`src/primitive/verb/pick.zig`).

Now `` `key=(some empty `S) `` → empty, `E@&…` on a 0-row table keeps typed
columns, and the editor/camera need no empty-frame guards.

## 8. `,/x` (raze via over) is O(n²) on long lists

Symptom: `,/icoTris` in `test/earth.k` — razing a 20480-element list of small
vectors — takes ~2.1s, while the JPEG decode feeding it is only ~33ms and the
subsequent transpose ~1ms. Timings scale with the square of the item count
(5120 items ≈ 130ms, 20480 ≈ 2.1s).

Cause: `over` with a builtin dyad (`src/primitive/adverb/fold.zig:59`) runs the
generic fold loop, calling the `,` concat verb n-1 times. Each concat allocates
a fresh array and copies the whole growing accumulator, so total work is
1+2+…+n = O(n²). The lambda path just above (fold.zig:45-57) already uses move
semantics (accum rc==1 → in-place append → O(n) amortised); the builtin path
does not.

Fix ideas: (a) route `,/` to a dedicated single-pass raze (sum lengths, allocate
once, memcpy each item), or (b) give the builtin-dyad fold path the same
move/in-place-append fast path the lambda path has (let `,` append into an
rc==1 accumulator). Worked around in earth.k for now by keeping the vertex count
low (texture supplies the detail, not geometry).

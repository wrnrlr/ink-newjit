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

## 5. `table , dict` (Insert) leaks on shape mismatch

`t , dict` dispatches to `M,m` = `insert.zig` (insert a *row* dict into a table).
When the dict doesn't conform to the table's columns it returns `!length` but
leaks the partially-built `new_data` (`insert.zig:25`): e.g.
`[[]a:1 2 3;b:4 5 6] , \`c!,7 8 9` → `!length` + a leaked `N(V)` allocation.
On the error path, free `new_data` (and any rows filled so far) before returning.
Separately: there is currently **no** table-aware *column* merge (update/extend
columns of a table from a column-dict); `M,m` is row-insert only. `dict , dict`
column-merge works fine, so dict-of-columns archetypes don't need this.

## 6. Slab free-size fragility — `Rc` header must stay ≤16 bytes (revisit later)

`array.deinit` (`src/noun/array.zig`) frees `data_offset + cap*@sizeOf(T)` instead
of the exact size `init` allocated. The slab allocator (`src/noun/slab.zig`) only
handles power-of-2 blocks and requires the **same** size on alloc and free, so this
reconstruction is correct ONLY when `data_offset` is a multiple of every element
size (1/2/4/8/16). The 16-byte `Rc` header makes `data_offset = 16`, which satisfies
that for all element types — so it works, but **by coincidence of the number 16**.

Growing `Rc` to 20/24 bytes (e.g. to add a field) makes `data_offset` not a multiple
of 16 (the `V`/dict element size); `cap = (total-data_offset)/size` then floors away a
remainder and `deinit` frees fewer bytes than allocated → DebugAllocator "alloc 64 /
free 56" mismatch. This is why the dirty-`epoch` stamp is packed into the existing
flags word (`meta: u32` in `rc.zig`) rather than added as a new field — the header
stays 16 bytes.

To make the header growable later, fix `deinit` to free the *actual* allocated size.
It's fiddly: `init` passes sizes >1024 through unchanged while `initWithCap` uses
`ceilPowerOfTwo` for >1024, so `deinit` can't blindly re-round — it must either store
the size class in the header or unify the two rounding paths. Not blocking; the
16-byte constraint is fine for now. Documented so the next header change doesn't
rediscover this the hard way.

## 7. `,fn` (enlist of a function) corrupts the function — FIXED

**Fixed** in `src/primitive/verb/enlist.zig`: the `Enlist` monadic jump-table struct
was missing the `_o` (lambda) and `_x` (object) signature fields, so enlisting either
fell through to the `typeError1` default — `,f` returned `!type`, hence `@,f` → `` `! ``.
The struct also carried three dead fields (`_y`, `_q`, `_v`) whose names aren't valid
`K` tags, so the dispatcher silently ignored them. Added `_o`/`_x` → `enlistListFn`,
dropped the dead fields. Now `@,f` → `` `L `` and `(,f)@0` is callable.

Enlisting a single function/lambda with monadic `,` produces a 1-element list whose
element is no longer callable: `f:{x+1}; @,f` → `` `! `` (not `` `L ``), and `(,f)@0`
applied to an arg → `!type`. A general-list literal `(f;g)` keeps its elements
callable (`@(f;g)` → `` `L ``, fold over it works), and `1#(f;f)` also yields a proper
callable `` `L ``. So the bug is specific to `,` (enlist) on a function value — it
likely takes a degenerate "list of partials/ops" path (`` `! ``) instead of a general
list. Hit while building `lib/ecs.k` (`ecsRun[a; ,sysMove]` failed); worked around by
having `ecsRun` accept a single system **bare** (detected via `@x ~ \`func`) and only
fold when given a real `` `L `` list. Fix: make monadic `,` on a function wrap it as a
1-element `` `L `` general list.

## 8. A `[...]` block as a `$[...]` branch hangs the parser

A square-bracket block used as a conditional branch makes the parser loop forever:

```k-repl
 $[1; (1;2;3); 0]      / OK — parenthesised list branch → 1 2 3
 $[x>0; [1;2]; 9]      / HANGS — never returns (whole-file parse never completes)
```

`$[cond; [a;b]; else]` never terminates (timeout / no output, since the file is
parsed before any execution). Parenthesised `(...)` branches are fine; only `[...]`
in branch position hangs. The conditional-branch parser has no terminating rule for a
`[` token where it expects a branch expression, so it spins. Hit while building
`test/ecs_demo.k` — a multi-statement change-detection branch written as
`$[e=old; skip; [rebuild; stamp]]` silently hung; rewriting the block as a helper
function (`$[e=old; skip; rebuild[e]]`) fixes it. Workaround: never put `[...]` in a
`$[]` branch — use a single expression or a helper fn. Proper fix: give the branch
parser an error/terminate path for an unexpected `[`. (Companion footgun: a
`keys!vals` length mismatch inside a frame callback throws and silently aborts the
rest of the callback — looks like "nothing renders / prints".)

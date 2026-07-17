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

## 8. `` `~ `` (and other op-glyph symbols) glue to a following backtick — Match needs spaces — FIXED

**FIXED**: the backtick-symbol lexer no longer consumes operator glyphs. After a
`` ` `` only alphanumerics and dots join the symbol; an operator glyph is its own
verb. So `` `~ `` is the null symbol `` ` `` followed by the Match verb (a
projection), `` `~` `` is a Match of two null symbols (→ `1b`), and `` `=` `` → `1b`,
matching ngn/k. To NAME a symbol after an operator, quote it: `` `"+" ``, `` `"<=" ``.
Op-glyph symbols like `` `+ `` / `` `<= `` are gone — every k source that compared
CST op values (`lib/dye.k`, `test/spirv.k`, `tools/lsp.k`) was migrated to the
quoted form. Original report below.

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

## 9. Special-symbol builtins apply by juxtaposition / brackets, not `@` — FIXED

**FIXED**: `marshal.zig`'s Unmarshal handlers register into `@`'s row for the
byte-ish operand types (`_s_C`/`_s_B`/`_s_s`/`_s_i`) but now delegate any non-`bin`
symbol back to `syms.apply`, so `@` routes all symbol-applies. `` `dir@"lib" ``,
`` `argv@0 ``, `` `asin@0.5 ``, `` `abs@3 `` all work. Original report below.

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

## 13. `2:"file"; expr` on one line panics (stack underflow) — FIXED

**FIXED** (with the nested-`2:` bug): a `2:` executed while another file/statement is
running now evals on its own re-entrant frame (`VM.evalNested`) instead of `interpret`
resetting the caller's stack. `2:"f"; expr`, `r:2:"f"`, and dye.k self-loading spirv.k
all work now. Original report below.

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
first. Cost time in `demo/clothbench.k`'s CPU cloth setup (areas → inverse masses
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
`im0[0,W-1]:0.`) in `demo/clothbench.k`'s size-parameterised setup functions —
the pins silently corrupted the mass array. Same family as the "`::` for globals
in lambdas" note, but specific to the *indexed* amend with a list index.

---

## 17. `` `c$-1 `` panics instead of erroring (cast to char from a negative int)

`` `c$<neg> `` (and `` `c$<neg vector> ``) reaches `numCast(i32, u8, v)` →
`@intCast`, which panics ("integer does not fit in destination type") in a Debug
build for any value outside `0..255`; in ReleaseFast it silently wraps/UB.
Present on `main` (was `.{ .c = @intCast(y.i) }` in `castInt`). Fix sketch:
clamp/mask like the u32→u8 path (`@truncate`), or return `.{ .err = .domain }`
for out-of-range. Applies to both the scalar and vector char casts in
`src/primitive/verb/cast.zig`.

---

## 18. Find (`?`) over a boolean-vector left operand returns empty

```k-repl
 0 1 0b ? 1b     / expected: 1  →  actual: (empty)
 0 1 0b ? 1      / expected: 1  →  actual: (empty)
 0 1 0  ? 1b     / 1   (int left operand works)
 0 1 0  ? 1      / 1
```

`x?y` (Find) yields an empty result whenever `x` is a boolean vector (`` `B ``),
regardless of the right operand's type. An int-vector left operand works, so the
bug is specific to the `B` code path in Find (`src/primitive/verb/`). Worked
around in `lib/dye.k` `constId` by using Where (`&mask`) instead of `mask?1b`.

---

## `@`(symbol, int-scalar) mis-dispatches to the `2:` loader — FIXED

**FIXED**: `marshal.zig`'s Unmarshal handlers (which register into `@`'s row for
C/B/s/i operands to support `` `bin@bytes ``) now delegate non-`bin` symbols back to
`syms.apply` (symbol-application), and `unmarshal_s_i` checks the symbol before
`getFileText`. So `` `abs@4 ``→4, `` `sin@0 ``→0.0, `` `foo@4 ``→!type (no panic).
Original report below.

Applying a symbol to an **integer scalar** via `@` panics instead of running the
symbol function:

```
`abs@4     / panic: index out of bounds: index 4, len 2  (→ unmarshal_s_i / 2: load)
`foo@3     / same panic — NOT math-specific; any symbol@int-scalar
`sin@2     / panic
`sin@2.0   / 0.9092974   (float arg is fine)
`sin@(2 3) / works        (vector arg is fine)
```

Root cause: `dispatch2(.@, s, i)` lands on the `2:` (Marshal) handler
`unmarshal_s_i` (marshal.zig:72), which does `getFileText(@intCast(y.i))` — using
the integer *value* as a file id. Only the `(symbol, int-scalar)` type pair is
affected; `(symbol, float)` and `(symbol, vector)` route correctly to `applySymFn`.

Impact: none on current code (nothing wrote `` `sym@int ``). Surfaced while wiring
lib/prelude.k (Phase 1); worked around there by applying math symbols via
JUXTAPOSITION (`` `sin x ``, which routes Call.apply → syms.apply, bypassing the
`@`-dyad table) instead of the `` `sin@ `` projection. Fixing the dispatch table
would let the projection form work too.

---

## 20. `json.parse` columnarises arrays of uniform objects (design note / API footgun)

`json.parse "[{\"x\":1},{\"x\":2}]"` returns the **table/dict** `{x: 1 2}`, not a
list of two dicts (`lib/json/main.zig` → `convertArr` → `tryTable`). Deliberate
for data-shaped JSON (array-of-rows → columns), but a footgun when navigating API
responses: xAI's `choices:[…]` and Anthropic's `content:[…]`/`tool_use` arrays
don't index as lists. Mixed-key arrays fall back to a general list `L` (fine); only
uniform-key object arrays collapse. RESOLVED for callers who need lists: added
`json.list` (native `ParseJsonList`, a `promote=false` variant of `json.parse`)
that keeps arrays as general lists — `lib/llm.k`'s agent tool-use path uses it to
navigate `choices`/`content`/`tool_use`. `json.parse` still promotes (intentional
for data-shaped JSON). Streaming still uses the small `llm.jstr` line scanner
(avoids parsing per chunk). Left open as a design note: the default `json.parse`
promoting surprises API callers — consider documenting or flipping the default.

---

## 19. Upstream (Zig 0.16 std): `std.zip.EndRecord.findBuffer` doesn't compile

`std.zip.EndRecord.findBuffer` (`lib/std/zip.zig`) is declared
`fn findBuffer(buffer) FindBufferError!EndRecord` where
`FindBufferError = error{ ZipNoEndRecord, ZipTruncated }`, but its body does
`if (pos + @sizeOf(EndRecord) > buffer.len) return error.EndOfStream;` —
`error.EndOfStream` is not a member of the declared set, so the function fails to
compile the moment it is referenced:

```
zip.zig:113: error: expected type 'error{ZipNoEndRecord,ZipTruncated}!zip.EndRecord',
             found 'error{EndOfStream}'
```

Upstream bug in the Zig standard library (0.16.0), not ink. It only bites when
the function is actually instantiated, which is why most code never hits it.
Worked around in `lib/zip/main.zig` (`findEnd`) by locating the End-Of-Central-
Directory record ourselves — `std.mem.lastIndexOf(buf, &zip.end_record_sig)` then
`@ptrCast(*align(1) const zip.EndRecord)` (little-endian host assumed). The rest
of the in-memory parse reuses `std.zip`'s `align(1)` extern struct layouts
(`CentralDirectoryFileHeader`, `LocalFileHeader`), which are fine. Revisit if a
future Zig fixes `findBuffer` (either the declared error set gains `EndOfStream`
or the body stops returning it) — the workaround can then be dropped.

---

## 21. Converge over a derived verb misapplies as a seeded fold (`,//x`) — FIXED

```k-repl
 ,/,/((1 2;3 4);(5 6;7 8))       / 1 2 3 4 5 6 7 8      — two razes, correct
 {,/x}/((1 2;3 4);(5 6;7 8))     / 1 2 3 4 5 6 7 8      — lambda converge, correct
 ,//((1 2;3 4);(5 6;7 8))        / (1 2;3 4;5;6;7;8)    — WRONG
 (,/)/((1 2;3 4);(5 6;7 8))      / (1 2;3 4;5;6;7;8)    — WRONG (same)
```

`f/x` where `f` is itself a *derived* verb (`,/`) does not run monadic converge.
The wrong output is exactly `x[0] ,/ x[1]` — a **seeded fold** (`x f/ y` with
`x[0]` as the seed and the remaining elements folded through dyadic `,/`) — so
the valence resolution for a derived-verb operand under `/` picks the
seeded-fold form instead of converge. A 1-param lambda operand (`{,/x}/`)
resolves correctly, which is the workaround used by `gpu.hold`'s flatten
(`{$[`L~@x;,/x;x]}/x`, lib/gpu.k). Likely home: `runtime/call.zig` /
`primitive/derived.zig` valence choice when the base of a derived verb is
itself derived. Found 2026-07-15 while adding shape recording to `9:`.

**Fixed 2026-07-16** in `primitive/derived.zig`: the monadic `/`/`\` valence
check (`derived2`) used `x.arity()==1`, but a derived over/scan verb (`,/`)
reports its dyadic *base* arity (2) while being monadically applicable. Added
`foldsAsMonad` — a `/`- or `\`-derived operand now reads as monadic converge,
not a seeded fold. Unit tests in `test.zig` ("converge over a derived verb").
`gpu.hold`'s flatten workaround simplified to `gpu.flat: {[x] $[`L~@x;,//x;x]}`
(the guard is now just the top-level list check; the per-step guard the lambda
needed is gone). The only behavioural delta from the old spelling is on inputs
that raze down to an *empty* vector (`(!0;!0)`→blank vs `!0`) — not a real GPU
upload, and gpu.hold's top-level `` `L~@x `` guard keeps `gpu.hold !0` safe.

---

# GPU shader compiler

Enhancement tracking for the SPIR-V shader compiler (`lib/dye.k`, `lib/spirv.k`,
`lib/gpu/gpu.zig`). These are missing capabilities, not correctness bugs — the
compiler emits valid SPIR-V for everything it supports.

## Open

### SPIR-V 1.4 upgrade — RESOLVED via the Vulkan/MoltenVK migration (2026-07-13)

**Outcome:** SPIR-V 1.4 is no longer blocked — it works on the new Vulkan/MoltenVK
backend (`-Dgpu-backend=vulkan`, `INK_SPV14=1`). The whole compute/nn stack runs on
genuine 1.4, bit-identical to 1.3. See `.plan/tasks.md` "GPU: Dawn → Vulkan
migration" and `doc/design/vulkan-migration.md`. The analysis below remains correct
for *WebGPU/Dawn* (which still refuses 1.4) and is why the migration was needed.

### SPIR-V 1.4 on Dawn — BLOCKED (unchanged; Dawn's Tint reader caps at 1.3)

Header is `0x00010300` (SPIR-V 1.3) in every emitter (vertex `buildMod`, all
compute variants). `OpEntryPoint` uses 1.3 subset-interface semantics — only
Input/Output builtins are listed (`iface: (,gidVar)` for compute; inputs +
single output for render); StorageBuffer / uniform-block / texture globals are
deliberately omitted.

**Tried it — Dawn rejects 1.4 outright.** Bumping the version word to
`0x00010400` and expanding every emitter's `OpEntryPoint` interface to list all
referenced global variables (the two changes 1.4 requires) was implemented and
tested. The prebuilt Dawn (`dawn_aarch64_macos` lazy dep) refuses the module
before running it:

    Tint SPIR-V reader failure: Invalid SPIR-V binary version 1.4 for target
    environment SPIR-V 1.3 (under Vulkan 1.1 semantics).

Dawn's ingestion target here is pinned to SPIR-V 1.3 / Vulkan 1.1, so *any* 1.4
module is invalid regardless of correctness. Both changes were reverted.

**A Dawn rebuild does NOT unblock this (investigated 2026-07-13).** The block is
not a target-env knob in this particular prebuilt — it is inherent to the WebGPU
raw-SPIR-V ingestion path. ink hands SPIR-V to Dawn via
`ShaderModuleSPIRVDescriptor` (`lib/gpu/gpu.zig`), which routes through Tint's
**SPIR-V reader**. That reader validates against the **Vulkan 1.1** environment
(`spirv-val --target-env vulkan1.1`), which caps input at **SPIR-V 1.3** (Vulkan
1.1↔SPIR-V 1.3; ingesting 1.4 would require the Vulkan 1.2 env). Dawn/Tint's own
docs state "SPIR-V 1.4 and later are not supported in Tint's SPIR-V reader." So
*no* Dawn version — rebuilt or newer prebuilt — accepts a 1.4 module through this
API. (The 1.4 support that shipped on Android/ChromeOS is Tint's *writer*,
WGSL→SPIR-V for the Vulkan backend — opposite direction, moot on macOS/Metal.)
Also: the vendored `dawn_aarch64_macos` prebuilt (michal-z) has no build newer
than July 2023, so there is no drop-in newer prebuilt anyway.

**Assessment:** the only capability 1.4 adds *for us* is `OpSelect` on
composite/array types (1.3 restricts it to scalars/vectors), which our
`$[cond;a;b]` branching doesn't need. Combined with the reader constraint above,
this is **WON'T-DO**, not merely deferred.

**Only routes that could ever run 1.4-era features (both out of scope):**
(a) emit or transpile to **WGSL** instead of raw SPIR-V (no version cap, but
rewrites the GPU back-end); (b) drop WebGPU for a raw **Metal/Vulkan** backend
(abandons Dawn). Neither is justified for an unused feature. See `.plan/tasks.md`.

### i32 / bool as shader I/O types

v3 is fully supported (incl. I/O). `bool` and `i32` exist in the type system
(`Tbool`/`Ti32`) and are used internally (comparisons, loop counters, buffer
indices, atomics), but `PtrIn`/`PtrOut` (`lib/spirv.k`) have no i32/bool entries,
so they cannot yet be declared shader inputs/outputs. **Fix:** add i32/bool
`PtrIn`/`PtrOut` pointer types.

### Multiple fragment outputs (MRT)

The vertex→fragment varying interface is multi-output (`shader.vertexU` emits up
to 4 varyings, each with its own `Location`), but fragment shaders emit a single
Location-0 color output — `buildMod` has no loop over multiple outputs. **Fix:**
generalise the fragment output var + `Location` decoration + store to a list of
outputs.

### User-facing int/float cast syntax

`OpConvertSToF`/`OpConvertFToS` (`opI2f`/`opF2s`) exist and are exercised
internally (index truncation, accumulator conversion) but there is no
shader-source cast (`int x` / `float x`) in `mathFns`. **Fix:** bind cast names
in the front-end to the existing convert stencils.

### Branching is eager `OpSelect` (no real control flow for expressions)

`$[cond;a;b]` compiles via `OpSelect` (`compCond`/`compCondS`), which is **eager**
— both sides are always evaluated. Real `OpBranchConditional` + `OpLoopMerge` +
`OpPhi` machinery exists but is reserved for bounded loops
(`loopOpen`/`compWhile`/`compNdo`/`rsum`/`rmax`). Consequence: a branch cannot
guard a side effect (why `scatterAdd`'s out-of-range guard selects value `0`
rather than skipping the store). Promoting conditional *expressions* to real
control flow is possible but not currently needed for pure expressions.

## Resolved

### Constant deduplication — DONE

`constId[t;v]` (`lib/dye.k`) caches every scalar `OpConstant` in parallel lists
(`ConKeyT`/`ConKeyV` → `ConVal`) keyed by type id + encoded word, so an identical
literal emits a single `OpConstant` per module. `compScalarLit`, `compVecLit`
(component constants) and the IR path `xLoConst` route through it; the cache
resets alongside `Con` at each module-reset site. Verified: four `1.0` uses emit
one `OpConstant`; i32 `0` and f32 `0.0` stay distinct (type in the key); 85/85
golden (`test/spirv.k`) pass. Not routed: the one-per-compile scaffold constants
(`Kzero`, `uniKIdx`, `CKz`, `CScope`, loop constants), already single-use.

### Configurable compute workgroup size — DONE

The workgroup size is the `wg` global in `lib/dye.k` (default 64), baked into the
`OpExecutionMode LocalSize` of all seven compute emitters. On the host,
`localSizeX` (`lib/gpu/gpu.zig`) parses `LocalSize` back out of the shader's
`OpExecutionMode` and divides the thread count by it in all four dispatch sites
(`gpuCompute`/`gpuCompute2` parse directly; `gpuComputeNew` stores it per pipeline
in `g_cwg`, used by `gpuDispatch`/`gpuDispatchLoop`). Because the host reads the
size from the shader itself, shader and dispatch stay in sync with no FFI change —
set `wg:128` before compiling to tune. Verified: default output byte-identical
(85/85 golden); `wg=16` over 100 elements dispatches 7 workgroups and writes all
100 (a stale /64 divisor would drop the tail); resident ping-pong unaffected.

### Headless compute (no window) — DONE

`gpuComputeRun[fn]` (`lib/gpu/gpu.zig`, exposed as `gpu.computeRun`) creates a GPU
device+queue with a hidden window (never shown), sets `g_renderer`, invokes the k
callback once, and tears the device down — all scoped via `defer`, so the
DebugAllocator asserts no leak. Compute (`gpu.runShader`, resident
`gpu.compileCompute`/`gpu.dispatch`) runs inside `fn` exactly as in a frame, with
no event loop. Results come back via a k global the callback assigns (`out:: …`),
mirroring `window.run`; the callback's return value is discarded (it is
VM-allocated and would trip the FFI return path's `c_alloc` free). Verified
end-to-end: one-shot double `1..5`→`2..10` and resident element-wise double both
correct, stderr leak-free. Caveat: still creates a hidden GLFW window, so it
needs a display/GLFW (headless in the no-visible-window sense, like `-snap`) — a
truly surface-less device would be a small patch to `patches/zgpu`'s
`GraphicsContext.create` (skip surface+swapchain), deferred as unnecessary.

### Uniform buffers in compute shaders — DONE

`shader.computeU` (`compComputeU` in `lib/dye.k`) emits an element-wise kernel
`{[x;u] …}` where `u` is a uniform `vec4` — a `Block`-decorated `struct{vec4}` in
storage class `2` (Uniform) at set 0 binding 2, loaded via the render path's
`loadUniMember`/`memberDecOne` helpers. On the host: `gpuUniformNew`
(`gpu.uniform`) creates a `.uniform`-usage buffer, and `gpuComputeNewU`
(`gpu.compileComputeU[spirv; nStorage]`) builds a pipeline with nStorage storage
bindings + one uniform binding at `nStorage`; the existing `gpuDispatch` binds it
positionally as the last handle. Verified: `{[x;u] (x*u[0])+u[1]}` computes
`3x+1` on `1..5`→`4 7 10 13 16`; updating the UBO with `gpu.write` and
re-dispatching gives `10x-2`→`8 18 28 38 48` without touching the data buffer; no
Dawn validation errors; 85/85 golden still pass. Scope: one uniform `vec4` on the
element-wise path; multi-member structs or uniforms on stencil/scatter kernels
would extend the same pattern (loop `memberDecOne`/`loadUniMember` over N members).

## snap.sh glob mismatch (pre-existing, found 2026-07-17)
`public/snap.sh` collects `"$name"-snap-*.png` but `ink -snap t` writes `$name-snap.png`
(no index suffix) for a single capture time — every demo is "skipped (no frame captured)".
Either glob `"$name"-snap*.png` or make the encoder always suffix.

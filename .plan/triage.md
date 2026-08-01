# Issues

## 27. A global named `t` "hangs" the process — FIXED (2026-08-01)

It was never a hang and never the compiler: `t: 5` was **autoloading half the
library**, ~11 s of module compilation in a Debug build before the first
statement ran. (`ink parse` was clean because parsing was never involved.) It
duplicated the "Assigning the bare global `t` hangs the interpreter" entry
below, whose diagnosis was right; the cascade behind it was the missing half.

Three compounding faults in `src/cmd/modules.zig`, all fixed:

1. **A namespace stem was indexed as a bare name.** `t.EVK:` in `lib/uitest.k`
   registered plain `t` → uitest.k, so any mention of `t` pulled the UI-test
   harness in. Same for `nn` (a local in `lib/slug.k`) → `lib/nn.k`. Stems now
   live in a separate `prefix` map consulted **only for a dotted reference**:
   `t.click` loads uitest.k, bare `t` does not.
2. **`autoLoad` scanned markdown block comments.** Every lib module opens with a
   `/` … `\` doc header, and that prose names other modules ("A ui.k frame is a
   pure function…", fenced `csv.read` examples) — so one reference dragged in a
   whole tree of unrelated modules. `autoLoad`/`scanDeps` now skip block
   comments (`isBlockFence`/`skipBlockComment`).
3. **A definition triggered an autoload.** `t:1` is a write; it can never need
   the module that exports that name. An identifier immediately followed by `:`
   is now skipped (`isBindTarget`).

Effect: `t:1` went 11.7 s → 0.26 s; `ui.*` loads 10 modules instead of 14 (10.4 s
→ 7.7 s). **`make ui-test` was broken by this and now passes** (31 assertions) —
it had read as a hang. `test/relpos.k`, which used to blow a 150 s timeout, now
finishes. Regression tests are in `src/cmd/modules.zig` (206 unit tests pass).

## 22. `lib/color.k` legacy HSL/pct helpers are broken (disabled) + a `\`-swallow lexer bug

`lib/color.k` could never be loaded (`2:"lib/color.k"`) because two legacy lines
choke the lexer:

- `perm:{,/'(|x,,s+&#*x)@*/1+\\~=1+s:#x}/[;!0]` — the literal `\\` (two backslashes)
  makes the lexer **swallow the rest of the file** (no output, no error). Replacing
  it with a single `\` lets the file load but then `perm 3` is `!type`, so the
  algorithm is broken regardless. `hsl2rgb` depends on `perm`.
- `tbl:+(-1+,/||:\!3)6!![6]+/:4*!3` (feeds `pct2rgb`) — the `||:\` similarly swallows
  the following line at load. `pct2rgb` unusable.

Because `perm` sat at line 4, the OKLCh palette + the new `oklch` converter below it
were unreachable. **Fixed for the palette path** by commenting out `perm`/`hsl2rgb`
and `tbl`/`pct2rgb` (2026-07-22); `2:"lib/color.k"` now loads and `oklch Blue500`
etc. work (verified bit-exact on the neutral ramp vs Tailwind hex). The HSL/pct
helpers remain DISABLED — reviving them needs (a) the underlying lexer bug fixed and
(b) the perm/tbl math rewritten for this dialect. Root cause of (a): `src/parser/
lexer.zig:184-207` — a `\` mid-expression, when the preceding token leaves the lexer
in a state where the `\`+next char looks like a command (`\letter…`, line 194), runs
`while … != '\n'` and eats to end of line. There is already a regression test
"lexer divider not swallowed by later backslash" (lexer.zig:632); `\\` and `||:\`
are cases it doesn't cover. Low priority (only bit legacy color helpers).

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

## 7. `walk.k` value-iteration amend returns `!type` — NOT A BUG (triage repro error)

The repro used `+/:` (each-**right**) which builds `W` as a `(#I, 4)` matrix, so
`+/x@W` reduces over the 64 outer rows → a length-4 vector, and the amend
`@[x;I(64);:;values(1)]` is a genuine length mismatch (`!type`). `test/walk.k`
itself uses `+\:` (each-**left**, line 21) → `W` is `(4, #I)`, so `+/x@W` sums the
4 neighbour rows → a length-64 vector matching `#I`, and the amend works. Verified:
`W:((-N),N,1,-1)+\:I` runs the whole relaxation cleanly. The amend path is fine.

```k
N:100;(r;c):1+!2#N-2;I:c+N*r;W:((-N),N,1,-1)+\:I   / +\: not +/:
f:{@[x;I;:;1.+.25*+/x@W]}
f (N*N)#0.0        / ok
```

---

## 11. `parse` of many files leaks IR-lowering scratch (Debug allocator)

Running the k language server (`tools/lsp.k`), which `parse`s every workspace
`.k` file to build a cross-file index, ends with a DebugAllocator leak report at
`src/compiler/compiler.zig:1025` (`lower`, the `offsets = alloc.alloc(usize, …)`
scratch). A single `parse` does not leak; it accumulates over many parses. Debug-
only (release uses `c_allocator`), so no functional impact, but the lowering
scratch for `parse`'d chunks isn't freed. Low priority.

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

# GPU shader compiler

Enhancement tracking for the SPIR-V shader compiler (`lib/dye.k`, `lib/spirv.k`,
`lib/gpu/gpu_vk.zig`). These are missing capabilities, not correctness bugs — the
compiler emits valid SPIR-V for everything it supports.

## Open

### SPIR-V 1.4 — RESOLVED (Vulkan/MoltenVK migration, cut over 2026-07-14)

`lib/dye.k` now emits SPIR-V **1.4 natively** (`0x00010400` + full-interface
`OpEntryPoint`) on the only backend, MoltenVK, which ingests it directly. The old
Dawn/WebGPU path (whose Tint SPIR-V reader was permanently capped at Vulkan 1.1 /
SPIR-V 1.3, and thus refused any 1.4 module) is deleted. Full history in
`doc/design/vulkan-migration.md`; migration status in `.plan/tasks.md`.

### Branching is eager `OpSelect` (no real control flow for expressions)

`$[cond;a;b]` compiles via `OpSelect` (`compCond`/`compCondS`), which is **eager**
— both sides are always evaluated. Real `OpBranchConditional` + `OpLoopMerge` +
`OpPhi` machinery exists but is reserved for bounded loops
(`loopOpen`/`compWhile`/`compNdo`/`rsum`/`rmax`). Consequence: a branch cannot
guard a side effect (why `scatterAdd`'s out-of-range guard selects value `0`
rather than skipping the store). Promoting conditional *expressions* to real
control flow is possible but not currently needed for pure expressions.

## Namespace member written only externally is invisible to internal readers (file-load)
A `\d ns` member that is only assigned from OUTSIDE the block (`ns.member:: v`) and read INSIDE by
bare name resolves to a DIFFERENT global than the external write, when the file is loaded via `2:`
or run as the main script. Repro: file `\d world; el:0.; probe:{[] el}; \d`; then `world.el::5`;
`world.probe[]` → 0 (should be 5). Inline it returns 5. Adding any internal write (`el::…` in a
namespace fn) makes both align. Likely compile-time name-mangling treating read-only members as
file-private. Workaround: set members via an internal setter fn. Found building demo/timer.k.

## A 5th vertex→fragment varying isn't delivered by shader.vertexPull/fragmentTexN (demo/earth.k)
Adding a 5th varying to the earth pipeline (wNor v3, wTan v3, wUvF v4, wSun v3, **wLay v2**) read as
0 in the fragment even when the vertex hardcoded it to 1.0 — the globe went black when output. The
first four varyings deliver fine (day/night via wSun, atmos via wUvF[3] both work). Oddly the STAR
pipeline in the same file has FIVE varyings (wRay v2, wRot v4, wScr v2, wPar v4, wSun2 v2) that all
deliver (the sun-gated halo uses the 5th). So it isn't a hard 5-varying cap — more likely a
location/packing interaction with the specific vec sizes (earth's 3+3+4+3+2) or with the 6-texture
fragmentTexN. Workaround used: pack the flag into a spare lane of an existing varying (wSun v3→v4,
bordersOn in .w). Worth pinning down the real rule in shader.vertexPull location assignment so
overlays can add channels without hunting for spare lanes.

## `&` on an empty general list errors, and `#` of an error is 1 — FIXED (2026-08-01)

Found while writing `lib/doc.k` (the API-doc extractor); `ink tools/doc.k -check
lib/agent.k` hung forever on a file with no comments in it. All three layers fixed:

1. `f'(0#0)` lost the element type — each over an empty typed vector yielded an
   empty general list. With nothing to call there is nothing to infer a result
   type from, so `each` now keeps the SOURCE's type (`promote.emptyOf`):
   ``@{[x]x}'(0#0)`` is `` `I ``, over `""` is `` `C ``, over `()` still `` `L ``.
   (`src/primitive/adverb/each.zig`.)
2. `&` on an empty `` `L `` raised `!type`. Where now has an `_L` kernel: an empty
   list has no true elements, so the answer is the empty index vector, and a
   non-empty list of bools/non-negative ints counts like `&I` does
   (`&(1;0;1)` → `0 2`). (`src/primitive/verb/where.zig`.)
3. `#` of an error VALUE returned 1 — TRUE — which is what turned (2) into a hang
   rather than a report: `$[#h; recurse; stop]` saw a truthy 1 and recursed
   forever. `#` now propagates the error (`src/primitive/verb/tally.zig`); the
   conditional takes the else branch.

Note the general question is still open: only `#` measured errors (it was the one
verb whose type list included `.err`), so this was a point fix, not a policy. Whether
`$[!type;a;b]` should propagate rather than pick `b` is undecided.

## Assigning the bare global `t` hangs the interpreter — FIXED, see issue 27

Both suggested fixes landed (a definition no longer autoloads; a namespace stem
only resolves through a dotted reference), plus the block-comment fault that made
the cascade big enough to look like a hang. Full write-up under issue 27 above.

## `=` key order sorted for I/S/B/C, first-occurrence for F/L — FIXED (2026-08-01)

Sorted for every key type now. The sorted-key guarantee is what makes the classic
`,/f'|=x!x<*1?x` quicksort work (it is exactly why k9 2021 can run it and ngn/k
cannot), so code relying on it silently got a different answer the moment the
grouped values were floats or lists:

```
=1.5 0.5 1.5 0.5      0.5 1.5!(1 3;0 2)       / was 1.5 0.5!(0 2;1 3)
=(2 2;1 1;2 2)        (1 1;2 2)!(,1;0 2)      / was (2 2;1 1)!(0 2;,1)
=3.0 1.0 0n 2.0 0n    0n 1.0 2.0 3.0!…        / 0n sorts first, matching `<`
```

`groupFloats`/`groupValues` sort the DISTINCT keys only — the same perm/rank
shape `groupHash` already used, so the added cost is over group count, not
element count. Floats order by the NaN-aware `sort.orderFloat`, general lists by
`sort.compareV` (the same total order `<` grades a list with; both are now
exported from `sort.zig`). `freq.zig`'s F/L kernels got the matching reorder
(`countsInKeyOrder`) so the `#'=x` peephole still agrees with `#'` over `=`
element for element — asserted in `src/test.zig`.

Two existing expectations encoded the old order and were updated: `==
"missisippi"` (the outer `=` groups by index-LIST values) and
`#'=(2 2;1 1;2 2)`.

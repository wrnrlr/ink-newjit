# Issues

## 27. A global named `t` hangs the process at COMPILE time

```k
t: 5
`0 0: "END"
```

hangs forever. Not a runtime hang — **nothing at all executes**, not even a print
placed *before* the assignment (`` `0 0: "before"; t: 5 `` prints nothing), so the
unit never finishes compiling. `ink parse` on the same file is clean, so the
parser is fine; it is the compiler or IR lowering.

- The value is irrelevant: `t: 5`, `t: 1 2 3`, `` t: `a`b!1 2 ``, `t: [[]a:1 2]`
  all hang. So does `t[0]: 5`.
- **`t` is the only single letter affected** — a loop over `a`…`z` assigning
  `1 2 3` hangs on `t` and nothing else. `tt`, `ts`, `t0`, `tb` are all fine.
- Not the module autoloader: it still hangs with `INK_HOME` pointed at a
  nonexistent directory, and there is no `lib/t.k`.
- Predates the IPC work — reproduced against a build of `cf7bf04` with the
  working tree stashed.

Found while writing `test/ipccli.k`, which named a table `t`; renamed to `tb` to
get around it. Nasty because the failure is total and silent: a script with a
`t` global produces no output and no error, so it reads as a hang somewhere else
entirely.

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

## `&` on an empty general list errors, and `#` of an error is 1 (silent infinite loop)

Found while writing `lib/doc.k` (the API-doc extractor); `ink tools/doc.k -check lib/agent.k`
hung forever on a file with no comments in it.

```
e: {[x]x}'(0#0)   / each over an empty typed vector -> empty GENERAL list `L
@e                / `L
#e                / 0
e=0               / ()      -- fine
&e=0              / !type   -- Where on an empty `L` is a type error
#&e=0             / 1       -- and `#` of an error value is 1, not an error
```

Three separate things, in increasing order of nastiness:

1. `f'(0#0)` loses the element type: each over an empty typed vector yields an empty
   general list rather than an empty typed vector. (`lib/doc.k` works around this by
   guarding every "no comments in this file" path explicitly.)
2. `&` on an empty `L` raises `!type` where it should give an empty index vector — an
   empty list has no true elements, so Where is well defined.
3. `#` of an error VALUE returns 1. That is what turned (2) into a hang instead of a
   report: `$[#h; recurse; stop]` saw a truthy 1 and recursed forever. Errors behaving
   like 1-element values is the general shape of the "silent wrong answer" failure mode
   — worth deciding whether primitives should propagate `!` instead of measuring it.

## Assigning the bare global `t` hangs the interpreter (autoload of lib/uitest.k)

`t:1` — nothing else in the script — never returns:

```
echo 't:1' | ink      # hangs forever
echo 'q:1' | ink      # fine
```

`lib/uitest.k` defines `t.EVK: …`, `t.VW: …` and friends at top level, so the module
indexer (`src/cmd/modules.zig` scanText) registers the dotted name AND its namespace
prefix — i.e. bare `t` → `lib/uitest.k`. Any mention of `t` then autoloads the headless
UI-test harness, which does not come back.

Two things are wrong here:

1. A *definition* (`t:1`) should never trigger an autoload — only a read of an unset
   name should. The write is what the user meant, and it can't need the module.
2. Indexing a one-letter namespace prefix like `t` poisons one of the most common
   variable names in the language for every script. Either uitest.k should use a longer
   stem (`uit.`), or single-character prefixes should be excluded from the index.

Found while implementing `<`/`>` on dicts and tables; the symptom there was that every
test script using `t:` for a table hung before printing anything.

## `=` key order is sorted for I/S/B/C but first-occurrence for F/L

`=x` sorts its keys for ints, symbols, bools and chars (the k7/k9-2021 contract),
but the float and general-list kernels return groups in first-occurrence order:

```
="mississippi"        "imps"!(1 4 7 10;,0;8 9;2 3 5 6)   / sorted
=2 1 2 2 1 1          1 2!(1 4 5;0 2 3)                  / sorted
=1.5 0.5 1.5 0.5      1.5 0.5!(0 2;1 3)                  / NOT sorted
=(2 2;1 1;2 2)        (2 2;1 1)!(0 2;,1)                 / NOT sorted
```

The sorted-key guarantee is what makes the classic `,/f'|=x!x<*1?x` quicksort
work (it is exactly why k9 2021 can run it and ngn/k cannot), so code that relies
on it silently gets a different answer as soon as the grouped values are floats or
lists. Either sort F/L too, or document that `=` only orders the scalar-key types.
`freq.zig` mirrors the same split deliberately, so both change together.

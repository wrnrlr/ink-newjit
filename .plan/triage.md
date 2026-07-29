# Issues

## 24. FIXED — VM stack limits, and a nested-call unwind that corrupted `current_chunk`

Originally filed as "kk elementwise chains are silently wrong at 28 ops". The emitter
was never at fault: `spirv-dis` showed the modules at 27/28/29 ops were valid and had
exactly the right `OpFAdd`/`OpFMul` counts. Three separate runtime defects, found by
following the chain-length cliff (`doc/research/tropical.md` §7):

1. **`FRAMES_MAX = 64` was far too shallow.** `kkClassify` (lib/dye.k) walks the CST by
   recursion, once per operator, so a 28-op kernel expression exhausted the VM's call
   frames. Raised to 4096 (a Frame is 32 bytes → 128 KB).
2. **A nested run swallowed its error and popped garbage.** `callLambdaAndRun`/`…Move`
   did `vm.runUntil(prev_frames) catch {}` and then `vm.pop()` — so a `StackOverflow`
   became a plausible-looking wrong number instead of an error. This is what made the
   28-op case return ~2x the right answer rather than failing. Now routed through
   `abortNested`, which returns an error VALUE (`!StackOverflow`).
3. **The unwind never restored `vm.current_chunk`** (neither the old `catch {}` nor the
   first version of `abortNested`). Execution resumed in the caller's frame while
   pointing at the abandoned callee's chunk, so the caller's ip indexed a foreign
   constant array — surfacing as `panic: index out of bounds: index 260, len 2` in
   `runUntil`, arbitrarily far from the real fault. `abortNested` now restores the
   parent's chunk by the same rule `doReturn` uses.
4. **`STACK_MAX = 2048` was the next wall.** With frames fixed, deep expressions ran the
   VALUE stack out instead; the emitter then silently produced a 167-word stub kernel.
   Raised to 16384.

Result: kk elementwise chains went from a hard cap of 27 ops (silently wrong at 28) to
correct GPU-vs-CPU agreement at 300 ops, verified across 27/28/32/64/100/128/200/300.
All oracle rungs stay green including kkgold byte-identity and spirv-val.

**Follow-up DONE: `kkClassify` is now a table scan** (lib/dye.k), so the classifier no
longer consumes a VM frame per operator and has no depth budget at all. Every rule in
the old `kkChk` was local — a node's verdict depends only on its own kind plus, for the
three apply-ish kinds, the operator slot it consumes — so the whole classification is
one pass over the CST rows. Row order is pre-order, which is exactly the order the
recursion reported offenders in.

Measured at 3000 ops: the recursive version produces no result; the scan returns in
~125ms. `kkClassifyRec` is retained purely as the reference implementation, and
`test/kkscan.k` (29 checks, wired into `test/oracles.sh`) asserts the two agree across
every CST shape plus a 200-op chain — a silent divergence would make kk accept or reject
the wrong kernels.

The raised `FRAMES_MAX`/`STACK_MAX` are still there and still worth keeping (other
recursive k code benefits), but kk no longer depends on them.

## 23. RETRACTED — `$lambda` does NOT drop parentheses (bad repro)

Filed during the tropical work as "a lambda taken out of a list loses its
parentheses when stringified, so kk.plan re-parses a different expression". **It is
not a bug.** The generator that produced the bench kernels was wrong:

```python
e = "x"
for i in range(k): e = f"({e}*1.0001)+0.0001"   # WRONG: e already ends in +0.0001
# k=2 emits ((x*1.0001)+0.0001*1.0001)+0.0001
# intended  (((x*1.0001)+0.0001)*1.0001)+0.0001
```

The round-trip was compared against the string I *meant* to emit rather than the one
actually emitted, so a faithful `$lambda` looked like it was dropping parens. Verified
directly on a ReleaseFast build — a parenthesised body round-trips identically whether
taken directly, out of a list, or out of a dict:

```k
TK2: {(((x*1.0001)+0.0001)*1.0001)+0.0001}
FS: (TK1;TK2)
(,/$ FS 1) ~ ,/$ TK2     / 1b
```

The two defects noticed alongside it ARE real and were verified independently — they
keep their own entry as #25.

## 26. FIXED — `gpuBufferFree` queue drain, and uninitialised `Vk` fields

Two things, one of which matters much more than the other.

**The real bug: `Vk` fields were never initialised.** Both constructors do
`var self: Vk = undefined` and then assign field by field, so struct-field DEFAULTS IN
THE DECLARATION ARE NEVER APPLIED. The `pending_len`/`pending_all` added for the
`gpuBufferWrite` fix were therefore garbage at startup — safe only because every read of
them is gated behind `recording`, which *is* explicitly set to false. That is luck, not
design. Adding a `dead_len` with no such gate turned the latent problem into a hang:
`sync()` walked `self.dead[0..garbage]` calling `vkDestroyBuffer` on junk handles, and it
hung at the first READBACK, before any free was issued. Both constructors now set every
field explicitly.

**The drain itself: real but small.** `gpuBufferFree` called `v.sync()` before destroying.
It now defers the destroy to the next `sync()` (`destroyLater`), so a free never drains.

Measured on an MHSA block (T=64, D=256, interleaved best-of, 3 rounds):
**1.03x** — inside the noise (rounds: 1.03x, 1.06x, 0.97x).

**The earlier estimate in this entry was wrong** and the reason is worth recording:
`sync()` opens with `if (!self.recording) return`, so a RUN of consecutive frees costs
ONE drain, not one per buffer. `lib/nn.k` frees its scratch in single `gpu.free'(...)`
batches, so a Conformer block was paying ~4 drains (one per batch), not the ~36 this
entry originally claimed. At ~250us a drain against a ~4800us block, that is ~3% — which
is what the measurement shows.

Kept anyway: the fix is correct, low-risk, and the field-initialisation half is a genuine
correctness fix independent of performance. But it is NOT the second 2x — the
`gpuBufferWrite` drain was expensive because it sat between dispatches and broke
pipelining; this one sits at a block boundary where a drain was about to happen anyway.

## 25. FIXED — kk silently returned ZEROS in two cases instead of failing

Both found while building the tropical benchmark harness. Neither errored; both handed
back a buffer of zeros that looked like a legitimate result. Both now fixed (lib/kk.k).

1. **A plan cached in one `gpu.computeRun` and reused in a later one.** `kkPlanCache`
   is keyed on (lambda source; #inputs; placement signatures) but NOT on the device, so
   the second session gets a plan holding pipeline handles from the destroyed first
   device. Repro: run the same `kk.plan` + `kk.run` in two consecutive
   `gpu.computeRun` blocks — the first is correct, the second is all zeros.
   **Fixed**: `kk.plan` now checks `gpu.gen` (the device generation counter lib/slug.k
   already uses) and drops `kkPlanCache`/`kkCache`/`kkGrpPipe`/caps on a change.

2. **A lambda whose params are not named `x`/`y`/`z`.** kk maps params positionally
   (`pn: nIn # \`x\`y\`z`), so `{[a] a+a}` compiles happily, binds nothing, and returns
   zeros. `kkClassify` reports clean, so `kkWarn` never fires. It should reject any
   lambda whose declared params are not the expected positional names.
   **Fixed**: `kkBadParams` rejects any lambda whose declared params are not `x`/`y`/`z`
   positionally, naming the offenders. Implicit-param bodies (no declared params) stay
   legal. Note `:expr` is not an early return in this dialect — the guard is a branch.

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

## Namespace member written only externally is invisible to internal readers (file-load)
A `\d ns` member that is only assigned from OUTSIDE the block (`ns.member:: v`) and read INSIDE by
bare name resolves to a DIFFERENT global than the external write, when the file is loaded via `2:`
or run as the main script. Repro: file `\d world; el:0.; probe:{[] el}; \d`; then `world.el::5`;
`world.probe[]` → 0 (should be 5). Inline it returns 5. Adding any internal write (`el::…` in a
namespace fn) makes both align. Likely compile-time name-mangling treating read-only members as
file-private. Workaround: set members via an internal setter fn. Found building demo/timer.k.

## Deeply-nested INLINE layout expression silently halts execution — FIXED 2026-07-30
Writing a nested `ui.col`/`ui.row` tree as ONE inline expression silently stops the script at that
statement — no error, exit 0, and every following top-level statement (incl. `window.run`) never
runs. Reliable repro (`2:"lib/ui.k"` first):
```
`0 0: "A"
y: ui.col[0.; (ui.row[0.; (ui.col[10.; (,ui.label["E"])]; ui.spacer[])); ui.spacer[])]
`0 0: "B"        / never prints
```
The SAME tree built in named steps works fine:
```
x0: ui.col[10.; (,ui.label["E"])]
x1: ui.row[0.; (x0; ui.spacer[])]
x2: ui.col[0.; (x1; ui.spacer[])]   / OK, "B" prints
```
So it's the inline nesting of bracket-calls inside parenthesized list literals `(call[…(…)…]; …)`,
not the layout itself. Minimal non-UI isolation with a dummy `f[g;x]` was inconclusive (ran to
completion), so the trigger is subtle — likely a compiler pass (constant-fold/DCE) on nested
list/dict construction, aborting the chunk silently. A silent halt with exit 0 is the dangerous
part. Workaround in demo/earth.k: build the HUD tree in named locals inside the lambda.

**Root cause + fix (2026-07-30):** the repro expression is genuinely UNBALANCED (an extra
`)`), and every closing bracket in the parser was consumed with `_ = self.eat(…)` — the
result discarded. A missing closer left the cursor parked on someone else's token, so the
production returned "successfully" and the rest of the file was swallowed: exit 0, no error.
All 12 sites now go through `Parser.close()`, which errors mid-source but stays lenient at
EOF (lib/syntax.k re-parses half-typed source on every keystroke to highlight, so `f:{[a;`
must still yield a partial tree). The repro now reports
`!parse_error: UnexpectedToken at 2:42` with a caret. No workaround needed — but note the
expression was malformed all along, so the "named steps" version was not just a workaround,
it was the correct code.

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

## `test/llm.k` fails to parse (`!parse_error: UnexpectedToken`) — FIXED 2026-07-30
`make test` runs `$(INK) test/llm.k` and it aborts immediately with
`!parse_error: UnexpectedToken`; nothing in the file is exercised. Pre-existing —
reproduces with an otherwise clean tree (confirmed by stashing unrelated changes),
so it is not fallout from the nn/ASR work. `make test` does not stop on it because
the recipe lines aren't `set -e`-guarded, so the failure is easy to miss.
Unrelated to this task; found while running the suite for demo/asr.k.

**FIXED:** once parse errors carried a location it took one line to see — the file had
`{[in] "You rolled a 4"}`, a lambda parameter named after the keyword verb `in`, which
the grammar rejects. Renamed to `arg`; the test now runs (18 assertions pass). Note the
`make test` recipe still isn't `set -e`-guarded, so a future failure there is still easy
to miss — worth fixing separately.

## A SPACED `\` is the scan adverb, never the split verb — FIXED 2026-07-30
`sep \ str` silently means "scan", so `"\n" \ 1: path` returned the whole file as a
ONE-element list instead of splitting it into lines. This is what made
`nnLoadVocab` (lib/nn.k) return a 1-entry vocab, so every detokenized transcript
came out empty. The glued forms `"\n"\s` and `NL\s` both split correctly; only the
spaced form is wrong. It is a silent wrong-answer rather than an error, which makes
it nasty — worth either rejecting `verb-adverb` where a dyad was clearly intended,
or at least calling it out in AGENT.md next to the other adverb-glue gotchas.

**FIXED:** the lexer tested `had_space` when deciding adverb-vs-adverb_val for `'` and
`\`. It no longer does — only the operand to the LEFT decides, so `sep \ str` means the
same as `sep\str` and `f ' xs` the same as `f'xs`. `/` deliberately KEEPS its spacing
rule, because ` / ` after a noun or verb is a comment; that asymmetry is now documented
in AGENT.md rather than being a silent trap.

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

## A lambda with 9+ parameters is accepted, then panics on partial application

The parser/compiler accept any number of lambda parameters, but the call machinery is
hard-capped at 8 in three independent places: `Fn.arity` is a `u4` (max 15),
`Partial.args` is a `[8]V` with a `u8` `fill` bitmask, and `doCallWithMode` marshals
through a fixed `[8]V` buffer (the compiler rejects a >8-arg *call site* with
`error.TooManyArgs`, which is the only cap that reports).

So a 9-param lambda can only ever be reached by projection, and that path is unsound:

```
f:{[a;b;c;d;e;g;h;i;j]a+j}
((((((((f 1)2)3)4)5)6)7)8)9
/ debug:       panic: integer does not fit in destination type
/                     call.zig:160  @as(u8,1) << @intCast(i)   with i=8
/ ReleaseFast: silently returns the 8-filled partial; merged[8] on a [8]V is OOB
```

`applyPartial` and `makePartialFromMerged` both loop `0..arity` over `[8]V` locals, so
arity 9..15 reads/writes past the end. Fix: reject >8 parameters at lambda *definition*
in the compiler (clear error at the point of the mistake), and assert the invariant in
`makePartialFromArgs`.

Related, and also silent: over-application drops the extra arguments instead of raising
`!rank` — `{[a;b]a+b}[1;2;3]` → `3`, `{x+y}[1;;3]` → `{x+y}[1;]`.

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

## `=` on a general list is O(n · distinct) — FIXED 2026-07-29

`groupValues` (and `freqValues`) linear-scanned the accumulated distinct keys with
`.eq` for every element, so an all-distinct list was quadratic:

```
L:,'!10000    #=L    0.16s
L:,'!20000    #=L    0.55s     / 2x the data, 3.4x the time
```

**FIXED:** `keying.Distinct` hands out group ids through a content hash of the
value (`keying.hashV`, ±0.0-normalized so it agrees with `V.eq`), with hash
buckets chained so exactness still comes from `.eq`. Now linear — `,'!10000` and
`,'!40000` both group in 0.01s, and the 1M-element `=L` bench line went 2561ms →
14ms at 100k distinct.

## Each over a dict drops the keys — FIXED 2026-07-29

`f'd` applied f to the dict's values and returned a plain list, so the canonical
group workflow lost its labels at the last step:

```
score@=player       [alice:1 8;bob:4 5;carol:2 7]   / good
|/'score@=player    8 5 7                           / ngn/k: `alice`bob`carol!8 5 7
```

**FIXED:** `each` now branches on the mapping types — a dict maps over its values
and comes back keyed the same way, and a table maps over its ROWS. The table half
also fixes an out-of-bounds read: `#t` counts rows but `t.at(i)` reads the i'th
COLUMN, so `{x}'` over a table with more rows than columns indexed past the end of
the column list.

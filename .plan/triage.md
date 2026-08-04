# Issues

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

---

## Monadic `|` (reverse) is not wired for a native table
`|t` on an `M` table returns `` `! `` — `reverse.zig`'s table entry is missing
(it has `_m: reverseDict` for `m` dicts, but no `_M`). This looks unintended
rather than by design: `pick.permute` explicitly handles `.M` ("a table gathers
rows, everything else gathers elements") and is documented as shared by the grade
AND reverse verbs, and grade-on-a-table works (`t@<t`col`, covered in
test/tables.k). So reverse is the odd one out — it should be one dispatch entry
routing through the same `permute` path sort.zig already uses.

Found while writing test/tables.k; not fixed there because it is a separate gap
from the row-gather work that test covers.

## `([])` builds an empty dict, not an empty table

`([])` (and, before the bracket change, `[[]]`) compiles to `+(()!())` — flip of
an empty dict — and `+` on an empty dict hands back an `m`, so `@([])` is `` `m ``
where it should be `` `M ``. Every non-empty form is fine (`@([]a:1 2)` is `` `M ``),
so this is only the degenerate case: an empty table cannot currently be spelled.

Pre-existing — the old `[[]]` spelling had the identical result, since both go
through compileDict's `n == 0` branch with `is_table` set. Fix belongs in the
monadic `+` kernel (flip of an empty dict should yield an empty table), not in
the compiler.

## Out-of-range index is `!length`, not a null fill — `y@!#x` does not port from k

In ngn/k (and k9) an index outside a list's bounds yields a **null of the source's
type** rather than an error, which is what makes `y@!#x` the standard "pad-or-truncate
y to `#x` items" idiom. Ink raises instead, for every type and both index shapes:

```
(1 2 3)@5        → !length      (1. 2. 3.)@0 1 5 → !length
(1 2 3)@-1       → !length      "abc"@5          → !length
(1.;`x)@5        → !length
```

So the readme's `plot` example — `` ax:`lo`hi`tk`px{x!y@!#x}/:(x;y) `` — cannot run
here. The whole point of that line is that a caller may write `-3.14 3.14 1.57` and
leave `px` off; the moment they do, `y@!4` errors instead of padding with a null. It
is line 1 of the snippet, so nothing after it is reachable. Porting the example to
`lib/plot.k` needed an explicit `plot.pad4:{[v] f:0.+v; f,(0|4-#f)#0n}` in its place.
`#` take is not a substitute: it repeats cyclically (`4#1 2 3` → `1 2 3 1`), not with
nulls.

"Absent" already answers two different ways: a missing DICT key returns `blank`
(`` (`a`b!1. 2.)`z `` prints nothing, `@` of it is the empty symbol), while an
out-of-range index errors. In k both are the typed null, so `^` fill and the
null-propagating arithmetic downstream keep working on either.

The bounds checks all live in `src/primitive/verb/pick.zig` — `pickAtom` (:265),
`pickTypedVec` (:106), `pickIntVec`'s generic-list branch (:130) and `pickVec` (:277),
each returning `.{ .err = .length }`; a fill would write the source type's null there
instead. Whether to change it is a real design call — erroring does catch off-by-one
bugs that k silently turns into nulls, and ink is not bound to k's choice. But if the
error stays, it should be stated in `doc/reference.md` and `AGENT.md` under `@`,
because every k programmer arrives expecting the fill and the failure is a hard stop
rather than a wrong number.

Side finding while diagnosing this: **monadic `$` on an error collapses it to
`!type`** — `$(1 2 3)@5` is `!type` while the value itself prints `!length`. `$` has
no `err` entry so it falls through to the default `.type`. That masks the real error
class in exactly the situation where a script is trying to report one, and it sent
this investigation down the wrong path for a while. Small, separable fix: `$` on an
err should render its symbol, like `format.zig` already does.

---

## An elided *middle* item in `$[…]` is dropped, not nulled — silent wrong branch

`$[c; ; x]` does not mean "if c then null else x". The empty item is **removed**,
so the form collapses to the two-item cond `$[c; x]` and a **true** `c` runs `x`:

```k
{[c] $[c; ; :99]; 7} 1b     / → 99   (expected 7)
{[c] $[c; ; :99]; 7} 0b     / → 7
{[c] $[c; :99; ]; 7} 1b     / → 99   (trailing elide: correct)
{[c] $[c; :99; ]; 7} 0b     / → 7
```

This contradicts the documented rule (CLAUDE.md, `doc/reference.md`): "only `;;`
and a trailing `;` inject a null element (the intended way to elide)". The
*trailing* elide behaves as documented; the *middle* one does not.

It matters now that `$[…]` branches can hold statements, because the natural
inverted guard — "if the precondition holds, fall through; else return early" —
is written exactly this way. It fails **silently**: no parse error, no runtime
error, just the wrong branch. Hit while refactoring `lib/regex.k` onto early
return (26 of 40 regex assertions went red from one such guard). The workaround
is to negate and use the trailing form, `$[~c; :x; ]`, which is what the code
now does everywhere.

Fix should either inject the null as documented, or make a middle elide a parse
error. Silently changing the arity of a cond is the worst of the three.

---

## `lib/svd.k` is broken by the prelude migration — `sqrt+/x*x` is a seeded fold

`svd` returns garbage today: `svd (3. 0.;0. 2.)` yields a matrix where the
singular-value vector `3.0 2.0` should be.

Cause is line 100, `s:{sqrt+/x*x}'A2`. Since the math functions became prelude
*names* rather than grammar keywords, a bare op-glyph directly after one is
**dyadic** — so `sqrt+/…` parses as the seeded fold `sqrt +/ (x*x)` with the
`sqrt` function itself as the seed, not as `sqrt[+/x*x]`:

```k
{sqrt+/x*x} 3. 0.      / → 9.0 0.0   (wrong)
{sqrt[+/x*x]} 3. 0.    / → 3.0       (right)
```

One-character fix (`sqrt[+/x*x]`), deliberately NOT applied here: the progn
refactor of that file was required to be behaviour-preserving and there is no
test for svd to re-baseline against. `lib/svd.k` has no coverage in `test/` at
all, which is why this went unnoticed — worth a `test/svd.k` alongside the fix
(reconstruction `A ≈ U·diag(s)·V'` and orthogonality `U'U ≈ I` both make good
assertions, and the module header already sketches them).

Same trap class as the `noun`-before-`+/` seeded-fold gotcha in `AGENT.md`; a
sweep of `lib/` for `<preludeName><opglyph>` would be worthwhile.

---

## `test/ir.k` does not terminate (times out well past its documented ~60s)

`.plan/lib-progn-refactor.md` lists `./zig-out/bin/ink test/ir.k` as "slow, ~60s".
It now runs past a 300s timeout, on an unmodified tree as well as a refactored
one. It prints all 15 of its `ok` lines — the last being `circle SDF via IR →
valid SPIR-V header` — and then hangs after the final assertion rather than
exiting, so the assertions themselves still pass. Pre-existing; unrelated to the
progn refactor (byte-identical output before and after).

---

## A tacit composition of two verbs prints as nothing

`@+:` and `@(+:)` evaluate to the compose-lambda `{f (g x)}` that
`compileTacitCompose` synthesises (compiler.zig), and that lambda is built with
`.start = 0, .end = 0` — so `formatFn` asks the file store for the source range
`[0,0)` and writes an empty string. The value itself is fine (`(@+:)1 2` works);
only its printed form is blank, which reads as "the expression produced null".

Pre-existing — byte-identical on `ff55a56`, unrelated to the `::` null change
that surfaced it. Fix is either to record the real source span of the composed
expression when building the lambda, or to have `formatFn` fall back to
reconstructing `f g` from the two operands when the range is empty.

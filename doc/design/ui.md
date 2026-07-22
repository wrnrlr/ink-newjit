# UI as an ECS of tables

A design for building GUIs in ink where **the UI is a table** — widgets are rows, traits are
columns, and a frame is a few whole-array passes over those columns. `lib/ui.k` is the toolkit
(one `ui` namespace: state, passes, flexbox, widgets); `lib/fmt.k` is number formatting. **All
seven** of the classic [7GUIs](https://eugenkiss.github.io/7guis/) are built on it:
`demo/{counter,temperature,flight,timer,crud,circle,cells}.k`.

## The thesis

Two ideas do all the work:

1. **Model and view are both tables.** The app's state is a table/dict (`COUNT`, a circle table,
   a cell grid). The view is *another* table derived from it each frame by a pure function. Undo
   is snapshotting a column (COW makes it free), CRUD is table ops, a spreadsheet is a column of
   formulas — the array language already has the data structure the UI needs.

2. **A frame is three vectorised passes.** No retained scene tree, no diffing:

   ```
   view   : model            -> widget rows      (pure; components are row-builders)
   input  : (widgets;events) -> fired actions     (hit-test = ONE point-in-rect over all rows)
   paint  : widgets          -> canvas ops         (each row → a fill/text; canvas re-batches)
   ```

   `view` rebuilds the whole widget table every frame. That's cheap — it's array construction —
   and it gives you React's mental model (`view = f(model)`) with none of the reconciliation.

## Storage: rows in, columns out

A widget is a **row-tuple**; a component is a function returning a **list of rows**; you compose
components with plain list `,`; `ui.build` transposes the row list **once** into a column dict
(the SoA archetype). Columns: `id x y w h bg txt fg sz act`. The transpose is why the input pass
is one array op — after `build`, `W`x` is the entire x-column.

```
button:{[id;x;y;w;h;s;act] ,mkw[id; x,y,w,h; blue; s; white; 16.; act]}
counter:{[x;y;n;key] (label[key;x;y+8.;"Count: ",$n]),button[key;x+150.;y;130.;36.;"count up";key]}
view:{[] ,/( panel[...] ; label[...] ; counter[...] ; counter[...] )}   / a list of row-lists
W: ui.build view[]                                                      / → column dict
```

Reuse is literal function reuse: `ui.counter` called twice with different keys is two independent
counters. A composite component just concatenates its children's rows.

## Input: hit-test is one array expression

```
hit:{[W;px;py] i:&((~px<x)&(px<x+w))&(~py<y)&(py<y+h); $[#i; *|i; -1]}   / topmost = last row
```

`&mask` gives the hit indices for the whole UI at once; the last is topmost (later rows paint on
top). The event table (`props`events`, columns `kind code mods down x y amt`) is filtered to
left-button-down rows and each dispatched to the action symbol under it. Actions are **data**
(symbols); the app's `onaction` gives them meaning. 100 widgets cost the same handful of array
ops as 3.

## State: three tiers

- **Model** — app-owned, the single source of truth. A dict/table. `onaction` mutates it.
- **Interaction state** (hover, focus, text-cursor, scroll) that must persist across the
  immediate-mode rebuild — a side keyed table `uistate` keyed by widget `id`, joined into the
  fresh widget table each frame (the `demo/recs.k` sparse-component **left join** pattern:
  `W , uistate`, 0-filling widgets that have none). This is the imgui "storage" trick, columnar.
- **Derived** — never stored, recomputed in `view` (a disabled flag, a validation result, a
  formatted label). Pure functions of the model.

Counter needs only the first tier. The later 7GUIs progressively light up the other two.

### Text input — the interaction tier, concretely

`layout.input[key; w; placeholder]` is a focusable, editable field, and it's the reference
implementation of framework-owned interaction state. Three globals in `ui` hold it, keyed by
widget id — surviving the per-frame view rebuild:

- `ui.buf`  — `id → string` buffer (the imgui storage dict). App reads/writes via `ui.get`/`ui.set`.
- `ui.focus` — the focused input's id (`` `none `` = none).
- `ui.caret` — caret column within the focused buffer.

The input is just a widget row with `act:`focus` (the marker) and `txt` = its buffer (or the grey
placeholder when empty+unfocused). What changes is the **frame entry point**, now `ui.frame[W;E]`,
which routes events two ways: a **mouse-down** hit-tests as before, but focuses the input under it
(and clamps the caret to the click x) instead of firing an app action — clicking elsewhere
defocuses; **text/key events** are dispatched to the *focused buffer* (insert/backspace/delete/←→/
home/end — the editing mechanics lifted verbatim from `demo/edit.k`, which stores lines as codepoint
vectors). `ui.frame` returns only the non-input (button) actions for the app. Paint draws a caret
bar for the row whose id is focused. So the app never touches focus or caret; it just binds a field
by key. Two-way binding (#2) is then: read `ui.get`c``, parse, `ui.set`f` the derived value.

## One namespace (`ui`)

Everything lives in a single `ui` namespace in `lib/ui.k`: interaction state, the frame passes, the
flexbox engine, the combinators, and the widgets. `layout.*` is gone (the split was a false
boundary); `lib/layout.k` is a deprecated shim that just loads `lib/ui.k`. Nested namespaces
(`\d ui.menu`) aren't supported by the compiler, so widget internals stay in `ui` as private
members (naming, not scoping); a genuinely large widget could be split to a `ui.table.*`-style set
of dotted globals if it ever earns one.

## Layout: flexbox (in `ui`)

You never hard-code x/y/w/h. You describe the UI as a **tree of nodes** — `ui.row`/`ui.col`
containers plus leaves (`ui.label`/`ui.button`/`ui.input`/`ui.select`/`ui.box`/`ui.spacer`) — and
`ui.solve` does the arithmetic. Two passes:

1. **`natSize` (bottom-up)** — each node's intrinsic content size. A leaf reports its own size (a
   label measures its text: FiraCode is monospace so width = `#s · sz · 0.6`); a container sums its
   children along the main axis and takes the max on the cross axis, plus gaps and padding.
2. **`solve` (top-down)** — given a node's assigned rect, place its children. The **main-axis
   offsets are a prefix-sum** of child sizes + gaps (`exPre = (+\x)-x`); leftover space (**slack**)
   is split among `grow` children by weight — a pure vector op. On the **cross axis** a child with a
   fixed size keeps it and is centred; a `0` (containers, backgrounds, spacers) fills. Combinators
   `grow`/`pad`/`sized`/`gap`/`bg` amend one field of a node dict and chain.

So a component is a function returning a node tree (`counter[key]` = a `row` of a sized label + a
button), composed by nesting. `layout.run[tree; props]` solves it over the **whole framebuffer
viewport** and returns the built archetype. No magic numbers; resize and DPI both just work.

The stack-as-scan / grid-as-outer-product identities are what make this cheap: a whole level of the
tree positions with one `+\`, not a per-node loop.

## DPI

`props`width/`height` are **framebuffer** pixels — on a 2× display the window you asked for is
twice as many pixels — and `props`mx/`my` come **pre-scaled into that same space**, so cursor and
drawing always agree (no conversion in hit-test). `props`dpr` is the ratio. The rule: **describe
the UI in logical units, pass `dpr` to `solve`, which scales the emitted geometry (rects and text
sizes) up to framebuffer px.** A layout laid out over `(width,height)%dpr` logical then scaled by
`dpr` fills the whole window and stays crisp at any density. The old bug — a hard-coded 640×360
panel filling a quarter of a Retina window — was exactly *not* doing this.

## State lives under `world`

App/UI state goes in a `world` namespace (`\d world`), addressed as `world.count`, `world.view`,
`world.act` — an ECS-style singleton "world". Namespaced dotted names support indexed compound
assignment (`world.count[key]:: 1 + world.count key`) both at top level and inside lambdas, so the
controller mutates the model in place without threading it through every call.

## Widget kit & composable state (`layout` + `ui`)

Leaves: `label`, `button`, `input` (focusable/editable, framework buffer), `select` (dropdown popup,
bound to a buffer), `slider` (drag-adjustable numeric, `ui.getv`/`ui.setv`), `progress` (gauge),
`list` (selectable rows, bound to an index), `canvas` (custom draw via `ui.onCanvas`, click →
`ui.cvx`/`ui.cvy`), `box`, `spacer`. Containers: `row`, `col`. Number
formatting is `lib/fmt.k` (`fmt.dec[n;x]` = fixed-width decimals, so a live value doesn't jitter). **Combinators** amend one field of the node dict and chain, so state-driven styling is pure
and declarative: `layout.disabled nd` (grey + `act:`nop` → uninteractive), `layout.invalid nd`
(red background), plus `grow`/`pad`/`sized`/`gap`/`bg`. A validated field is just
`$[ok; input[…]; layout.invalid input[…]]` in the `view`. `ui.draw[W;w;h]` wraps
`cnv.new`/`paint`/`cnv.render` — the whole per-frame render.

**Overlays (solved, no native change).** Every canvas quad — fills *and* glyphs — is drawn at a
constant `z=0.5` with `LESS_OR_EQUAL`, so occlusion is pure **painter's algorithm: last draw wins**.
Within one `cnv.render` all fills draw before all text, so an overlay in the *same* render can't hide
base text — but a **second `cnv.render`** composites on top of the first (frame order is
`fills₁,text₁,fills₂,text₂`, so render-2's fills cover render-1's text). So `ui.draw` renders the
main UI (render 1) then the open dropdown's menu rows (render 2). `select` is a real popup again.
Cap: **2 render passes per frame** (the Slug scene buffer is double-buffered, `SCNF=2`); enough for
a menu or one modal — nested overlays would need `SCNF` bumped (a one-line native change). #6's
radius dialog rides the same path.

## Render: why per-row emit is still batched

`paint` calls `cnv.rect`/`cnv.text` per row, which *reads* like immediate mode — but `lib/canvas.k`
records every fill/stroke/glyph into one columnar **ops table** and `cnv.render` bins them all into
a **single resident Slug scene buffer drawn in one pass**. So the k-level loop is just recording;
the GPU sees one batched, analytic, resolution-independent draw. Text, gradients, clips, and images
all ride the same buffer.

## The 7GUIs on this architecture

The point of the set is that each task stresses a different axis, and the table/array framing pays
off *more* as they get harder:

| # | Task | What it stresses | How it maps |
|---|------|------------------|-------------|
| 1 | **Counter** | trivial state | model = one int; `view` formats it; click bumps it. **Done** (`demo/counter.k`). |
| 2 | **Temperature** | two-way binding | the two `ui` input buffers *are* the state; each frame read the FOCUSED field, and if it parses, write the converted value into the other (invalid → leave it). No separate model. **Done** (`demo/temperature.k`). |
| 3 | **Flight Booker** | validation, enable/disable | a `select` (mode) + two date inputs; validity/enablement are **pure derived functions** of the buffers, recomputed in `view` — an invalid date wraps its input in `layout.invalid` (red), the return field / Book button in `layout.disabled` (grey + inert). **Done** (`demo/flight.k`). |
| 4 | **Timer** | time, progress, drag | the render loop *is* the clock (`props`time` → elapsed, clamped to duration); `ui.progress` gauge = elapsed/duration; `ui.slider` (drag-adjustable) sets duration; Reset zeroes it. First mouse-*move*-reactive widget (`ui.frame[W;props]` tracks a drag + reads `props`mx` each frame). **Done** (`demo/timer.k`). |
| 5 | **CRUD** | collections, filter | model **is a table** (parallel name/surname columns); filter = prefix-match mask over the surname column, create = append, update = amend-at-index, delete = mask-out — every op an array op. `ui.list` shows the filtered rows (click → index by geometry; selected row highlighted). **Done** (`demo/crud.k`). |
| 6 | **Circle Drawer** | custom draw, undo/redo | model = circle columns `(cx;cy;cr)`; a `ui.canvas` widget delegates paint to `world.paint` (via `ui.onCanvas`) which strokes/fills each circle; **undo/redo = a stack of column snapshots**, nearly free under COW — a few lines. Radius editor is an inline bar with a slider. **Done** (`demo/circle.k`; the old SDF shader → `demo/sdf.k`). |
| 7 | **Cells** | dataflow, dependency graph | model = two dicts (`RAW` text, `VAL` numbers); a formula (`=A0+B1*2`) is evaluated by a tiny tokenizer (cell-refs + `+-*/`, left-to-right); any edit **recomputes the whole sheet to a fixpoint** (a few whole-sheet passes — cheap, array-native), so dependents update automatically. There's no built-in string→value eval to reuse (`.` parses only literals, `exec` is a shell verb). **Done** (`demo/cells.k`). |

The through-line: **CRUD is a table, undo is a snapshotted column, Cells is a dependency graph over
columns, validation is a derived column.** The ECS-of-tables framing isn't just for laying out
widgets — it's the natural shape of the application state these GUIs are *about*.

## Flexbox vs. constraint (Cassowary) layout

**Recommendation: flexbox now (built), Cassowary later as an optional module — not the default.**

Flexbox fits this architecture because it's **O(n) and vectorisable**: two passes of prefix-sums /
reductions over the child list, re-run every frame with the immediate-mode rebuild at no meaningful
cost. It's predictable (you can read a layout off the tree), and it composes with "a component
returns a node subtree." It covers rows, columns, stacks, grids, spacing, flexible fill, and
alignment — enough for all seven GUIs.

Cassowary (the constraint solver behind AutoLayout/Kiwi) is strictly more expressive — you state
relations (`a.right + 8 = b.left`, `all buttons equal width`, priorities) and an incremental simplex
solves them. Its costs are the reason it isn't the default: it's an **iterative solver** (bad fit
for solving from scratch each frame; it wants persistent, incrementally-edited constraints — i.e. a
retained layout, against the immediate-mode grain), it's a real amount of code to get right, and its
generality is wasted on the box-stacking that 95% of UI needs. Where it *shines* is
irregular/relational layouts and, notably, a **visual layout editor** — dragging widgets and
pinning constraints, solving live. That's a great standalone project (`lib/cassowary.k` + a
`demo/layout-editor.k` draw app) and a good showcase of the language, but it's a peer to flexbox for
special cases, not a replacement. Build it when a UI actually needs relational constraints; reach
for flexbox for everything else.

## Dialect gotchas found building this (see also AGENT.md)

These bit us repeatedly; nearly all fail **silently** (a wrong number, or a black frame — never an
error). Building on this stack means internalising them.

- **8-param lambda cap** — group args into a vector (`rect = x,y,w,h`). Dict *construction*
  (`keys!vals`) has no cap, so wide nodes are dicts, not lambda args.
- **A noun before an op-glyph makes it dyadic.** `ui.label $r` parses as `ui.label $ r` (dyadic
  format) → a broken `!` dict; `ui.label ,x` → dyadic join. **Bracket the arg: `ui.label[$r]`.**
- **Single-char strings are atoms.** `#`, indexing, `.`-parse, and `~`-match all differ from
  multi-char vectors (`"M"~1#x` is false: atom vs 1-vector). Normalise via codepoints
  (`(0#0),`i$s`) or force a vector (`. (0#" "),t`).
- **`str , list` flattens the string's chars.** Enlist first: `(,str), list`.
- **`I _ s` cut drops everything before the first index.** Prepend 0: `(0,&op)_s`.
- **`table,table` doesn't row-concatenate** (merges columns → 1 row). Build a list of row-tuples and
  transpose once with `+`; or append row-dicts as `demo/recs.k` does.
- **Newline inside `[...]` separates arguments; inside `{}` separates statements.** A multi-line
  `,`-chain in either splits — build the list in a local, or `,/` a paren-list.
- **Lambdas don't close over locals.** A fold/each body can't see the enclosing function's locals;
  fold over self-contained data (`{applyOp[x; y 0; y 1]}/[…]`), not over locals.
- **A namespace member written only from *outside* (`ns.m::`) is invisible to inside readers when
  file-loaded.** Give it an internal setter and call that (see `.plan/triage.md`).
- `f'[a;b;c;…]` is each over conforming lists (maps `solve` across `X;Y;W;H`).
- `@` and `$dict`key` are right-greedy / mis-parse near operators — bind first, or parenthesise.
- No `>=`: `px≥x` is `~px<x`. `,/()` is a unit not `!0`. `*/0#10` is a unit not 1.

---

## API reference (`ui`, in `lib/ui.k`)

**Setup / state.** `ui.setFont[face]`; `ui.get[k]`/`ui.set[k;str]` (text buffers), `ui.getv[k]`/
`ui.setv[k;x]` (numeric, sliders), `ui.setFocus[k]`. Interaction state lives in module-level dicts
keyed by widget id: `buf` (text), `val` (numbers), `opts` (select/list items), plus scalars
`focus`, `open`, `caret`, `drag`.

**Leaves (each returns a node dict).**
- `ui.label[str]` — text, intrinsic size.
- `ui.button[str; act]` — clickable; fires `act` on click.
- `ui.input[key; w; placeholder]` — focusable text field; buffer `ui.get/set[key]`; caret + editing.
- `ui.select[key; w; options]` — dropdown popup (overlay); selected value in `ui.get[key]`.
- `ui.slider[key; w; min; max]` — drag-adjustable; value in `ui.getv/setv[key]`.
- `ui.progress[frac; w; h]` — gauge (0..1).
- `ui.list[key; items; w; h]` — selectable rows; selected **index** in `ui.getv/setv[key]`.
- `ui.cell[id; label; w; h; hl]` — grid cell; click fires `id`; highlighted when `hl`.
- `ui.canvas[key]` — custom draw: set `ui.onCanvas[{[x;y;w;h]…}]`; a click stores `ui.cvx`/`ui.cvy`
  and fires `` `canvas ``.
- `ui.box[color]`, `ui.spacer[]`.

**Containers.** `ui.row[gap; kids]`, `ui.col[gap; kids]` (kids = a list of nodes).

**Combinators (amend one field; chain).** `ui.grow[w; nd]`, `ui.pad[p; nd]`, `ui.sized[w; h; nd]`,
`ui.gap[g; nd]`, `ui.bg[color; nd]`, `ui.disabled[nd]` (grey + inert), `ui.invalid[nd]` (red).

**Frame passes.** `ui.run[tree; props]` → widget table `W` (solve + build + overlay). `ui.frame[W;
props]` → app actions (handles focus/menu/slider-drag/list/canvas + keyboard; call
`{app.act x}'` over the result). `ui.draw[W; w; h]` → render (main pass + overlay pass). Also
`ui.hit`, `ui.paint`, `ui.solve`, `ui.natSize`, `ui.measure` for lower-level use.

**The standard frame loop** (every demo):
```
run:{[props]
  W: ui.run[app.view[]; props]
  {app.act x}' ui.frame[W; props]
  ui.draw[ui.run[app.view[]; props]; props`width; props`height]}
```

---

## Roadmap — remaining work, ranked

1. **Test framework (DONE for logic/interaction — see below).** `lib/uitest.k` + `test/ui.k` (26
   assertions) regression-guard layout/hit-test/action-dispatch and the full interaction surface
   (focus, text editing, slider, select, list) via `make ui-test`. Remaining: the native PIXEL path
   (`gpu.shot` + a persistent headless render context) for golden-screenshot diffs.
2. **Codify the gotcha list into a lint/checklist**, and push the clearest compiler bug
   (namespace-external-write) upstream via `.plan/triage.md`.
3. **Scrolling** for `list`/`grid` (needs clip + content offset in the geometry pass).
4. **Generalise the overlay** so dialogs float (currently dropdown-only; dialogs use inline bars);
   lift the 2-render/frame cap (bump `SCNF`) if nested overlays are needed.
5. **Multiple UI contexts** — the interaction state is global singletons; no independent sub-UIs /
   multiple windows.
6. **Performance at scale** — profile full-rebuild + re-solve + per-row paint beyond ~50 widgets;
   Cells recompute is O(cells²).
7. **Polish:** field alignment (start/center/end), number-only input, proportional-font text
   metrics (currently monospace-only), theming (palette is hardcoded constants), error surfacing
   (a bad input blanks the frame instead of showing a message), resize-stable coordinates.
8. **Richer formula language** in Cells (precedence, parens, ranges, functions) — currently a
   left-to-right toy.

---

## Test framework — BUILT (harness + full logic/interaction suite); pixel tests remain

**Status (2026-07-22).** The pure-k harness and a regression suite exist and run headlessly:

- **`lib/uitest.k`** — the `t.*` harness. It builds the SAME `kind/code/mods/down/x/y/amt`
  `props`events` table the native window feeds `ui.frame`, then drives `ui.run` + `ui.frame` (the
  real input + flexbox path — no window, no GPU). `t.app[view;act]` registers a view thunk + action
  handler; `t.click/rclick/down/up/move/type/key/scroll/wait/frame` each drive one frame; `t.W[]`,
  `t.find`, `t.rect`, `t.val`, `t.acts[]` inspect the resulting widget table; `t.eq/ok/truthy/err`
  assert with a tallied `t.report[]`. Coords are logical at dpr=1.
- **`test/ui.k`** — 26 assertions, deterministic, covering flexbox layout (grow/gap/pad, row+col),
  intrinsic sizes, hit-testing (topmost + misses), action dispatch, and the FULL interaction surface:
  focus/defocus, **text editing** (type / backspace / ←→ / home / end / mid-string insert), slider
  drag, dropdown open→pick→close, and list selection. `make ui-test` (and `make test`) run it.

  All interaction state — typed buffers, caret motion, slider/select/list values — commits headlessly
  through the real `ui.frame` path. (An earlier investigation mistook a **test-code parsing gotcha**
  for a VM bug: `"…",ui.get`fx,"…"` parses as `ui.get @ (`fx,"…")` — `` dict`key `` before an
  operator — and `step ,ev` parses as `step , ev` — `,` after a noun is dyadic. Both are AGENT.md
  gotchas; the runtime and ui.k are fine. Read state into a variable first, and enlist with `(,ev)`.)

**Still to build:** the native pieces for PIXEL tests (below) — `gpu.shot[path]` + a persistent
headless render context — plus golden PNGs and screenshot-diff assertions. `t.shot` is a stub today.

---

## Test framework — original plan (pixel path still open)

**Goal:** deterministic, replayable UI tests that reuse the *real* input + render path, so a test is
"drive these events, assert model/geometry, and screenshot-diff the pixels."

**Why it fits:** input is already a **table** (`props`events`) and time/cursor are injected via
`props`, so a frame is a pure function of `(model, props)`. A test is a *scripted event stream*
replayed frame by frame — no live window needed. With `Date.now`/random out of the app (time comes
from `props`time`), replays are byte-deterministic → golden screenshots work.

**Shape of a test (all in k):**
```
/ actions build the props`events table the app already consumes, then call run[props]:
t.click[x;y]      / a `mouse down/up event pair
t.type["=A0+B1"]  / `text events (codepoints)
t.key[259]        / a `key event (backspace, arrows, …)
t.move[x;y] / t.wait[dt]     / cursor / advance props`time
t.shot["cells-c0-selected"]  / capture the framebuffer to a PNG (a test ACTION)
/ assertions are plain k:
t.eq[world.count; `c1`c2!1 0]           / model state
t.eq[#W`x; 6]                            / geometry / hit-test
t.shotMatches["cells-default"]           / screenshot vs golden (byte or perceptual diff)
```

**Native pieces needed (small, the machinery exists in `gpu_vk.zig` snap path):**
1. A **persistent headless render context** — like `-snap` but driven frame-by-frame from k rather
   than capturing one frame and exiting. Options: a `window.test[run; script]` native driver, or
   expose `gpu.testBegin[w;h;dpr]` / `gpu.testEnd[]` so k drives the loop and owns assertions.
2. A **k-callable screenshot verb** — `gpu.shot[path]` that blits the current offscreen target to a
   PNG on demand (reuse `writeSnapPng` + the offscreen target; today it's env-triggered + one-shot).
3. Event injection is **pure k** — the harness builds the same `kind/code/mods/down/x/y/amt` table
   `ui.frame` already reads, so no native input mocking.

**Deliverables next session:** `lib/uitest.k` (the `t.*` harness), a golden-PNG directory, the two
native verbs above, and a `make ui-test` target that replays each demo's script and diffs. Start by
converting the throwaway logic checks we wrote this session into the first real tests.

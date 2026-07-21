# UI as an ECS of tables

A design for building GUIs in ink where **the UI is a table** — widgets are rows, traits are
columns, and a frame is a few whole-array passes over those columns. `lib/ui.k` is the minimal
kernel; `demo/counter.k` is 7GUIs #1 built on it.

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

## Layout: flexbox (`lib/layout.k`)

You never hard-code x/y/w/h. You describe the UI as a **tree of nodes** — `row`/`col` containers
plus leaves (`label`/`button`/`box`/`spacer`) — and `layout.solve` does the arithmetic. Two passes:

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
| 1 | **Counter** | trivial state | model = one int; `view` formats it; click bumps it. **Done.** |
| 2 | **Temperature** | two-way binding | model = one canonical value (°C). Both fields are *derived views*; editing either parses → writes °C. Bidirectional binding = single source + derived columns. |
| 3 | **Flight Booker** | validation, enable/disable | model = `(mode;d1;d2)`. Validity is a **derived column** computed by a pure function; the button's `disabled`/`bg` is a function of it. |
| 4 | **Timer** | time, progress | the render loop *is* the clock: `props`time` feeds `elapsed`; progress-bar width = `elapsed%duration`. No threads. |
| 5 | **CRUD** | collections, filter | model **is a table** of names; the list widget is a direct view of a filtered column (`&prefix~/:names`); create/update/delete = row append / amend / mask. |
| 6 | **Circle Drawer** | custom draw, undo/redo | model = a circle table `(x;y;r)`; draw = a vectorised pass of `cnv.circle`; **undo = a stack of model snapshots** — free under COW columns. |
| 7 | **Cells** | dataflow, dependency graph | model = a grid table with `formula`/`value` columns; the dep graph is an **edge table**; recompute = topo-sort over columns then `exec` each formula. The array-language showcase. |

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

- Lambdas cap at **8 params** — group related args into a vector (rect = `x,y,w,h`); dict
  *construction* (`keys!vals`) has no such cap, so wide nodes are dicts, not lambda args.
- `table,table` does **not** row-concatenate (it merges columns → 1 row). Concatenate **row lists**
  and transpose once with `+`, or append single row-dicts as `demo/recs.k` does.
- Inside a `{}` body a **newline is a statement separator** — a multi-line `a ,b ,c` becomes three
  statements and returns only the last. Keep a concatenation on one line, or build a paren-list
  (which *may* span newlines) and `,/` it.
- `f'[a;b;c;…]` is each over conforming lists — the workhorse for mapping `solve` across a level's
  per-child `X;Y;W;H` vectors.
- `@` (index/apply) is right-greedy: `(W`x)@i + k` parses as `(W`x)@(i+k)`. Parenthesise:
  `((W`x)@i)+k`.
- No `>=`: `px≥x` is `~px<x`.
- `table,table` does **not** row-concatenate (it merges columns → 1 row). Concatenate **row lists**
  and transpose once with `+`, or append single row-dicts as `demo/recs.k` does.
- Inside a `{}` body a **newline is a statement separator** — a multi-line `a ,b ,c` becomes three
  statements and returns only the last. Keep a concatenation on one line, or build a paren-list
  (which *may* span newlines) and `,/` it.
- No `>=`: `px≥x` is `~px<x`.
- `$dict`key` mis-parses when an operator sits either side — bind the value first (`v:d`k; $v`).

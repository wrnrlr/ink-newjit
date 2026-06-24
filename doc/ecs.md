# ECS — archetypal entity-component-system in ink

`lib/ecs.k` is a Bevy-style **archetypal ECS** written in ink. This document
records the design, the full API, the language/runtime features built to support
it, the gotchas hit along the way, and what's still open.

## 1. Core insight

An archetypal ECS *is* a columnar database, and a columnar database is what an
array language is built for. In a Rust/C++ ECS the archetype storage is a
hand-rolled struct-of-arrays; in ink it's free: an **archetype is a dict of
equal-length column vectors**, a **query is selecting columns**, and a **system
is a whole-column array operation**. The per-entity `for` loop that dominates a
typical ECS disappears into vectorized array ops (`px +: dt*vx` over a whole
column at once).

Two consequences shape everything:

- **Full scalar SoA.** Components are decomposed to flat, homogeneous scalar
  columns (`px py pz`, not a `pos` column of `(x;y;z)` triples). This is faster
  (contiguous typed vectors) and sidesteps ink's weak spots with general-list
  dict values. A "component" is therefore a *set of field columns*.
- **Systems are global functions** `archetype -> archetype` doing whole-column
  work. ink lambdas don't close over parent scope, which *forces* the ECS
  contract: a system receives exactly the data it operates on as arguments.

## 2. Two layers

The library has a low layer (manipulate archetypes directly) and a high layer
(a world that routes by component-set signature):

| Layer | Hold state as | Component add/remove | Use when |
|---|---|---|---|
| **Archetype** | each archetype is its own global (`Movers::`, `Statics::`) | name src+dst archetypes explicitly (`ecsMove`/`ecsAddComp`) | few fixed archetypes, full control |
| **World** | one `world` dict threaded with `::` | auto-routed by signature (`addComponent`/`removeComponent`) | many archetypes, dynamic component sets |

Cross-cutting facilities (sparse-set side-tables, command buffer, stage
scheduler, dependency ordering, hierarchy, change detection, GPU offload) work
with both.

## 3. Data model

```k
/ An archetype is a dict of equal-length columns; the `id column holds entity ids.
movers: `id`px`py`vx`vy!(0 1 2; 0. 1. 2.; 0. 0. 0.; 1. 1. 1.; 0. 0. 0.)
```

- **Entity id**: a stable integer from `ecsId[]` (monotonic global `ecsNxt`).
- **Component**: a named set of field columns, declared in a registry (world) or
  implied by the archetype's column set.
- **Archetype identity**: its canonical (sorted-distinct) component-name set.

## 4. API reference (`lib/ecs.k`)

### Archetype storage
```
ecsId[]                fresh monotonic entity id
ecsArch[proto]         empty archetype from a prototype row (col -> sample value); include `id
ecsSpawn[a;row]        append one entity (row = full column dict incl id) -> archetype
ecsWhere[a;mask]       sub-archetype of rows where boolean mask is true
ecsKill[a;eid]         remove the entity with id = eid
ecsCount[a]            number of live entities
ecsRow[a;eid]          an entity's row as a dict (incl id)
```

### Component add/remove (archetype moves — the defining op)
```
ecsMove[src;dst;eid;add]   relocate a row: dst cols from row if present else `add`; drop src-only cols -> (src2;dst2)
ecsAddComp = ecsMove       add a component, supplying its fields in `add`
ecsRemoveComp[src;dst;eid]  move to the sparser archetype (dropped fields vanish)
```

### Sparse-set side-tables (rare / optional / churny components)
A sparse component is a dict `entityId!value` — cheap add/remove, **no archetype
move**. Use for components few entities have or whose membership changes often.
```
ssetNew[]                  empty sparse set
ssetSet[s;eid;v]           add/update an entity's value
ssetDel[s;eid]             remove an entity
ssetHas[s;eid]             membership
ssetGet[s;eid;dflt]        value or default
ssetMask[a;s]              boolean mask over a's rows: which have the component
ssetAlign[a;s;dflt]        the sparse value as a column aligned to a's rows (default-filled)
```
`ssetAlign` is the join that lets a dense system read a sparse component:
`(a\`px)+ssetAlign[a;Boost;0.]` applies a boost only where present.

### Systems & scheduling
```
ecsRun[a;systems]          run a single system (bare) or a list, left to right
schedRun[sched;a]          run a schedule (dict stageName!systems, in key order), flushing the
                           command buffer at each stage boundary
ecsRunDeps[a;specs]        run systems in dependency order (specs = (name;fn;after)); topo-sorted
ecsDepOrder[specs]         resolved system names (inspect; short result = a cycle dropped systems)
```
A system is a function `archetype -> archetype`. Pass one bare (`ecsRun[a;
sysMove]`) or a list (`ecsRun[a; (sysMove;sysGrav)]`); a 1-element enlist
(`,sysMove`) is fine too.

### Command buffer (deferred structural change)
Systems must not add/remove rows mid-frame (it invalidates indices and hierarchy
links). They enqueue; `ecsFlush` applies at a stage boundary.
```
ecsCmdSpawn[row]           enqueue a spawn (into global ecsSpawnBuf)
ecsCmdKill[eid]            enqueue a despawn (into global ecsKillBuf)
ecsFlush[a]                apply buffered kills then spawns, clear buffers
```

### Hierarchy (apter trees)
A scene/UI hierarchy is a flat **parent-index column** `par` (self-loop roots,
`par[r]=r`). The `depth` builtin gives per-node depth; propagation processes
nodes in `<depth par` order (parents before children).
```
ecsPropagate[par;local]    additive transform propagation: world[i] = local[i] + world[par[i]]
```
For 4×4 transforms, swap `+` for matrix-compose and gather the parent matrix.

### World (auto-routing registry)
A `world` is a dict `[reg; sigs; archs; loc]`: a component registry (name ->
field-prototype dict), a parallel list of canonical component-sets and their
archetypes, and an entity->archetype index. It routes add/remove by signature so
callers never name src/dst.
```
worldNew[reg]                      empty world from a component registry
worldSpawn[w;comps;vals]           spawn with a component set -> (w; eid)
addComponent[w;eid;comp;vals]      add a component; entity auto-moves to the richer archetype
removeComponent[w;eid;comp]        remove a component; auto-moves to the sparser archetype
worldArch[w;comps]                 the archetype for a component set (empty if absent)
worldApply[w;comps;sys]            run a system on one archetype, write it back
worldCount[w;comps]                live entity count for a component set
```

### Cross-archetype queries
A query reaches **every archetype whose component set ⊇ the query** — movement
runs on all moving entities regardless of their other components.
```
worldQuery[w;comps;sys]            run a system on every superset archetype, in place
worldEach[w;comps;seed;f]          fold a reader over every superset archetype (aggregates)
```

### Change-filtered query (Bevy's `Changed<T>`)
Runs a system only on archetypes whose watched column changed since last time,
via the `epoch` version stamp. `filt` is per-query state (archetype-index ->
last-seen epoch); thread it.
```
worldQueryChanged[w;filt;comps;watch;sys] -> (w2; filt2)
```
For consumers (render-prep, derive world transforms) that should re-run only when
their input dirtied.

### GPU compute offload
An archetype column is a flat f32 vector = a compute-shader buffer. Element-wise
systems lower to SPIR-V (`ComputeShader`/`ComputeShader2`) and run on the GPU
(`RunShader`/`RunShader2`). Requires `lib/gpu.k`+`lib/spirv.k` and a `gpuRun`
frame. Compile the shader once; dispatch per frame.
```
ecsOffload[a;col;shader]            run a 1-input kernel {[x] f(x)} on a column, write back
ecsOffloadAll[a;cols;shaders]       offload several columns, each with its own shader
ecsOffload2[a;out;c1;c2;shader]     run a 2-input kernel {[x;y] f(x,y)} on two columns -> out
```
`ecsOffload2` does true `px += vx*dt` integration on the GPU.

## 5. Runtime / language features built for the ECS

These live in the ink runtime, not the library:

- **`depth`** (keyword verb) — apter-tree node depths from a parent vector, O(n)
  memoized; cycles → `!domain`. (`src/primitive/verb/depth.zig`)
- **`epoch`** (keyword verb) — per-array version stamp for change detection;
  fresh at allocation, bumped on in-place mutation. Packed into the `Rc` header's
  flag word so the header stays 16 bytes. (`epoch.zig`, `rc.zig`, `value.zig`)
- **`freq`** + `#'=` peephole — fast frequency count; the compiler recognizes the
  `tally-each over group` idiom and emits a direct `freq`. (`freq.zig`,
  `compiler.zig`)
- **amend conform** — `@[d;keys;:;vals]` distributes element-wise when lengths
  match (matching `d[keys]:vals`); atoms broadcast. (`amend.zig`)
- **global indexed assign / scatter-add** — `name[i]::v` and `name[i]+::v` write
  back to a global from inside a lambda; `+` accumulates on duplicate indices
  (true scatter-add). (`compiler.zig compileBind`)
- **two-input GPU compute** — `gpuCompute2` (binding 0=in1, 1=out, 2=in2),
  `compCompute2`/`ComputeShader2`, `RunShader2`, plus **arity-3 FFI**
  (`ffi_vtable_3`/`call3_fn`). (`lib/gpu/gpu.zig`, `lib/spirv.k`, `lib/gpu.k`,
  `src/ffi.zig`, `src/noun/plugin.zig`, `src/runtime/call.zig`)
- **allocator-ordering fix** — the VM now builds the chunk and compiler via the
  slab so literal constants are allocated and freed by the same allocator
  (`vm.zig`; see doc/bug.md #9).

## 6. Test files (runnable demos)

| File | Demonstrates |
|---|---|
| `test/ecs.k` | archetype storage, spawn/kill, a system, hierarchy `depth`/propagate |
| `test/ecs_move.k` | component add/remove (archetype move) |
| `test/ecs_stages.k` | sparse-set join + stage scheduler + command-buffer despawn |
| `test/ecs_world.k` | auto-routing world: add/remove by signature, archetype reuse |
| `test/ecs_query.k` | cross-archetype `worldQuery` + `worldEach` aggregate |
| `test/ecs_changed.k` | `Changed<T>` filter — skip unchanged archetypes |
| `test/ecs_deps.k` | intra-stage dependency ordering (topo sort) + cycle detection |
| `test/ecs_compute.k` | 1-input GPU offload of columns (gravity, damping) |
| `test/ecs_compute2.k` | 2-input GPU offload — `px += vx*dt` on the GPU |
| `test/ecs_demo.k` | `RunWindow` particle fountain: systems + cmd buffer + change-detection + batched render |

All pure-data tests are headless; the `*_compute*` and `*_demo` ones open a GPU
window. Run e.g. `./zig-out/bin/ink test/ecs_world.k` (headless) or
`timeout 6s ./zig-out/bin/ink test/ecs_compute2.k` (GPU).

## 7. Gotchas (ink idioms that bit us)

Recorded here because they recur when writing ECS code; deeper notes in
`doc/bug.md`:

- **No `>=` / `<=`** — `i>=0` parses as `i>(=0)` (garbage). Use `i>-1` / `~(i<0)`.
- **`col\`field` before a verb** needs parens: `(a\`vx)*dt`, not `a\`vx*dt`.
- **each binds tightly**: `}'xs`, never `} ' xs` (a space mis-parses).
- **`last` is a reserved keyword** (the `last` verb) — don't use it as a variable
  name (`last:expr` doesn't bind). Same for `first/count/parse/sum/min/max/depth/
  epoch/in/…`.
- **symbol-vec = symbol-atom doesn't broadcast** (`c=\`x` → `!type`); use
  `c in ,\`x`.
- **int-keyed dict `@` is positional** (`s@9 7` → `!length`); key-lookup is
  `(.d)@(!d)?k` (the `dget` helper).
- **`,fn` corrupts a function** — pass a single system bare, a list as `(f;g)`.
  (Fixed in `enlist.zig`, but the bare/list convention stays.)
- **`0#\`sym` (empty symbol vec) as a list element breaks the parse** — use `()`
  for "no items"; **`,0!,0` parses as `,(0!,0)`** — build small dicts via amend on
  `()!()`.
- **converge `f/x` can hang** for fixpoint loops — use bounded count `(#n) f/x`.
- **`$[cond; a; [stmt;stmt]]`** (a `[...]` block branch) hangs the parser — use a
  helper fn; and **multi-line `(...)` list literals inject nulls** — keep list
  literals on one line.
- **`keys!vals` length mismatch inside a frame callback** throws and silently
  aborts the rest of the callback (looks like "nothing renders").

## 8. Design rationale (recap)

- **Columnar SoA over native tables.** The native `[[]...]` table type leaks on
  per-row indexing (`t@&mask`) and materializes a dict per row; a dict-of-columns
  filters per-column with no row materialization, leak-free and faster.
- **Hybrid storage.** Dense/hot/co-queried components → archetype columns;
  rare/optional/churny → sparse-set side-tables. The rule of thumb: if a component
  changes which-entities-have-it more than once every few seconds, make it sparse.
- **Deferred structural change.** Spawn/despawn go through the command buffer and
  flush at stage boundaries, keeping row indices and hierarchy links stable
  mid-frame.
- **Apter-tree hierarchy.** A flat parent-index column + `depth` keeps the scene
  graph columnar; propagation is level-batched (one vectorized op per depth).
- **GPU is the real parallelism.** ink is single-threaded, so system-level
  concurrency isn't a lever; the data-parallel win is lowering element-wise
  systems to compute shaders.

## 9. Status & roadmap

**Done:** columnar storage, spawn/despawn, queries (single / cross / change-
filtered), command buffer, archetype moves, auto-routing world, sparse-set
tables, stage scheduler, dependency ordering, apter-tree hierarchy, change
detection, GPU offload (1- and 2-input). Ten test files, all green; build clean.

**Open / could be added** (roughly by leverage):

- **Fold `ecsRunDeps` into `schedRun`** — let a stage be given a dependency-spec
  list directly, so ordering is declarative within the normal scheduler.
- **Multi-column change-watch** — `worldQueryChanged` watches a single column;
  generalize to "changed if any of N watched columns moved."
- **Empty-archetype pruning** — world archetypes accumulate as entities move
  through component sets; prune empties (and compact `sigs`/`archs`/`loc`).
- **Query caching** — `worldQuery` recomputes the superset match every call;
  cache the matching archetype indices, invalidated when `sigs` grows.
- **N-input / cross-archetype compute** — extend compute offload past 2 inputs,
  and integrate it with `worldQuery` so a hot system offloads across all matching
  archetypes.
- **Resources / singletons** — a clean abstraction for Time/Input/Camera instead
  of ad-hoc globals threaded alongside the world.
- **Events / messaging** — a buffered event channel for system-to-system
  communication (and to decouple producers/consumers).
- **Entity relationships** — general entity references and many-to-many links
  beyond the single-parent hierarchy.
- **Serialization** — save/load a world (columns serialize trivially; ids and the
  registry need care).
- **Better cycle reporting** in `ecsRunDeps` — currently a cycle silently drops
  its systems; surface the offending names.
- **A UI/widget layer** — the original motivation: UI widgets as hierarchical
  entities (layout = a top-down + bottom-up sweep over the same apter tree that
  drives 3D transform propagation).
- **System-level scheduling IR** — borrow the Tiramisu separation of *algorithm*
  vs *schedule* to annotate systems (run on CPU vectorized / fuse with the next /
  lower to GPU) without rewriting their logic.

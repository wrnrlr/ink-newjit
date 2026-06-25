/ lib/ecs.k — archetypal ECS (pure data; no GPU required)
/
/ Each archetype is a dict of equal-length columns (scalar struct-of-arrays); the
/ `id column holds entity ids. Systems are plain functions archetype -> archetype that
/ operate on whole columns (the per-entity loop disappears into array ops). Helpers are
/ global (lambdas don't close over scope).
/
/ TWO layers, lowest first:
/   - archetype primitives — Archetype/aPush/ecsWhere/ecsKill/ecsMove/Tick operate on a
/     single archetype value you hold yourself. Used directly for fixed archetype sets,
/     and internally by the world.
/   - the singleton World — ONE world per app, held in the global `wld and mutated in
/     place via `::. World[reg] creates it; Spawn/Despawn/Endow/Divest route by
/     component-set signature; Query/Survey/Watch run systems across archetypes. No
/     world value is ever threaded through a call (see the `World section below).
/
/ Hierarchy uses apter trees: a flat `par parent-index column + the `depth builtin for
/ level-batched transform propagation (Cascade). Self-loop roots (par[r] = r).

ecsNxt:: 0
ecsId: {[] i:ecsNxt; ecsNxt::ecsNxt+1; i}            / fresh monotonic entity id

/ Archetype[proto] — empty archetype from a prototype row: a dict mapping each column
/ name to a sample value (establishes the column set AND each column's type).
/ Include `id in the proto. e.g. ecsArch `id`px`vx!(0;0.;0.)
Archetype: {[proto] (!proto)!{0#x}'.proto}

/ aPush[a;row] — append one entity row to an archetype (the low-level column zip). `row
/ is a dict with a value for every column of `a (incl `id). Returns the new archetype.
/ Internal: callers use the singleton World's Spawn, which routes + assigns id for you.
aPush: {[a;row] (!a)!{[a;row;k]((a k),row k)}[a;row]'!a}

/ ecsWhere[a;mask] — the sub-archetype of rows where boolean `mask is true.
ecsWhere: {[a;mask] m:&mask; (!a)!{[a;m;k](a k)@m}[a;m]'!a}

/ ecsKill[a;eid] — remove the entity whose id = eid.
ecsKill: {[a;eid] ecsWhere[a; ~(a`id)=eid]}

/ ecsCount[a] — number of live entities.
ecsCount: {[a] #a`id}

/ The defining archetypal operation: changing an entity's component set moves its
/ row to a different archetype. ecsRow extracts a row; ecsMove relocates it.

/ ecsRow[a;eid] — entity eid's row as a dict (column -> value), including `id.
ecsRow: {[a;eid] i:(a`id)?eid; (!a)!{[a;i;k](a k)i}[a;i]'!a}

/ ecsMove[src;dst;eid;add] — relocate entity eid from archetype src to dst. For each
/ column of dst the value is taken from the entity's src row if that column exists
/ there, else from `add (the dict of newly-added component fields). Columns in src
/ but not in dst are dropped. Returns (src2; dst2): src with the row removed, dst
/ with it appended.
ecsMove: {[src;dst;eid;add]
  row:    ecsRow[src;eid]
  dstRow: (!dst)!{[row;add;k]$[k in !row; row k; add k]}[row;add]'!dst
  (ecsWhere[src; ~(src`id)=eid]; aPush[dst; dstRow])}

/ ecsAddComp[src;dst;eid;vals] — add a component: move the entity to the richer
/ archetype dst, supplying the new fields in `vals (a dict). Returns (src2; dst2).
ecsAddComp: ecsMove

/ ecsRemoveComp[src;dst;eid] — remove a component: move the entity to the sparser
/ archetype dst (fewer columns; the dropped fields vanish). Returns (src2; dst2).
ecsRemoveComp: {[src;dst;eid] ecsMove[src;dst;eid;()!()]}

/ ── sparse-set side-tables (rare / optional / churny components) ─────────────────
/ A sparse component is JUST a dict entityId!value — no new type, no constructor.
/ Keyed by id (dense iteration via !s ids / .s values), cheap to add/remove for one
/ entity, and it does NOT move the entity between archetypes — use it for components
/ few entities have or whose membership churns (Selected, Hovered, a timer…).
/
/ The language IS the API for the obvious ops, so there are no wrappers for them:
/   empty   ()!()  (or [])                 has     eid in !s
/   set     @[s;eid;:;v]  (s[eid]::v global)   delete  eid _ s
/ Only the non-obvious read gets a helper: an int-keyed dict indexes POSITIONALLY
/ with @ (s@9 is the 9th value, not key 9), so a value lookup must go through find.
ssetGet: {[s;eid;dflt] $[eid in !s; (.s)@(!s)?eid; dflt]}   / value at key eid (positional-find) or dflt

/ ssetMask[a;s] — boolean mask over archetype a's rows: which have the component.
ssetMask: {[a;s] (a`id) in !s}

/ ssetAlign[a;s;dflt] — the sparse value aligned to a's rows (dflt where absent), a
/ column usable directly in a system. Default-fill, then scatter present values in.
ssetAlign: {[a;s;dflt]
  ids:  a`id
  vals: (#ids)#dflt
  hit:  &ids in !s
  @[vals; hit; :; (.s)@((!s)?(ids@hit))]}

/ Tick[a;systems] — thread an archetype through system(s), left to right. A system
/ is a function archetype -> archetype; this is just the k pipeline fold {y x}/ ({y x}
/ applies the next system to the accumulator). `/ over an atom applies once, over a
/ list folds — so the SAME body handles a bare system (Tick[a; sysMove]), a list
/ (Tick[a; (sysMove;sysGrav)]), and a 1-element enlist (,sysMove) with no dispatch.
Tick: {[a;systems] a{y x}/systems}

/ Structural changes (spawn/despawn) are deferred so systems never mutate the row
/ set mid-frame (which would invalidate indices and hierarchy links). Systems
/ enqueue; ecsFlush applies everything at a stage boundary.
ecsSpawnBuf:: ()        / pending rows (dicts) to append
ecsKillBuf::  0#0       / pending entity ids to remove

ecsCmdSpawn: {[row] ecsSpawnBuf,:: ,row; 0}   / enqueue a spawn (full column dict)
ecsCmdKill:  {[eid] ecsKillBuf,:: eid; 0}     / enqueue a despawn by entity id

/ ecsFlush[a] — apply buffered kills then spawns to archetype a, clear the buffers.
ecsFlush: {[a]
  a: $[#ecsKillBuf; ecsWhere[a; ~(a`id) in ecsKillBuf]; a]
  a: a{[acc;r]aPush[acc;r]}/ecsSpawnBuf
  ecsKillBuf:: 0#0; ecsSpawnBuf:: ()
  a}

/ ── stage scheduler (ordered system groups) ─────────────────────────────────────
/ A schedule is a dict stageName!systems, BUILT IN STAGE ORDER (the dict's key
/ order is the run order), e.g.  `update`cleanup!((sysMove;sysBoost); sysReap).
/ Each stage's value is a single system (bare) or a list of systems. schedRun runs
/ the stages in order, applying each stage's systems with Tick and flushing the
/ command buffer at the stage boundary — so a stage's deferred spawns/despawns are
/ visible to later stages (and applied before the frame ends).
schedRun: {[sched; a] a{[sched;acc;st] ecsFlush[Tick[acc; sched st]]}[sched]/!sched}

/ ── intra-stage ordering by dependencies (topological sort) ─────────────────────
/ A system spec is (name; fn; after): a `name symbol, the system `fn, and `after — a
/ symbol vector of system names this one must run AFTER (() or 0#`sym for none).
/ ecsRunDeps topologically sorts the specs by their `after constraints and runs the
/ systems in that order, so you declare WHAT must precede WHAT, not the list order.
/ A dependency cycle is unsatisfiable: the systems in it are dropped (use ecsDepOrder
/ to inspect — a short result vs the spec count means a cycle).
ecsReady: {[deps;pn;i] d:deps i; (#d)=+/d in pn}      / are entity i's prereqs all placed yet?
ecsGrow:  {[names;deps;placed]
  pn:names@placed; idx:!#names;
  rem:idx@&~idx in placed;
  m:ecsReady[deps;pn]'rem;
  placed,rem@&m
}
ecsTopo:  {[names;deps] (#names) ecsGrow[names;deps]/(0#0)}   / topological order (indices)

/ ecsDepOrder[specs] — the system NAMES in resolved dependency order (for inspection).
ecsDepOrder: {[specs] nm:{[s]s 0}'specs; nm@ecsTopo[nm; {[s]s 2}'specs]}
/ ecsRunDeps[a;specs] — run the systems on archetype a in dependency order.
ecsRunDeps:  {[a;specs] fns:{[s]s 1}'specs; Tick[a; fns@ecsTopo[{[s]s 0}'specs; {[s]s 2}'specs]]}

/ ── World: the singleton archetype registry ─────────────────────────────────────
/ There is ONE world per application, held in the global `wld and mutated in place
/ via `:: — no threading, no w parameter. It routes component add/remove by component-
/ set SIGNATURE so callers never name src/dst archetypes. `wld is a dict:
/   reg   — component registry: compName -> field-prototype dict (field!sample), e.g.
/           `Position`Velocity!([px:0.;py:0.];[vx:0.;vy:0.])  (establishes columns+types)
/   sigs  — list of canonical component-sets present (sorted-distinct symbol vectors)
/   archs — list of archetypes (column-dicts), parallel to sigs
/   loc   — dict entityId -> index into sigs/archs (which archetype it is in)
/   filt  — change state for Watch: watchCol -> (archIndex -> last-seen epoch)
/ Deep in-place writes (wld[`archs][i]:: …) drill straight to the target slot — no
/ copy of the archetype list, no rebuild of the world dict. That is the whole reason
/ a singleton is faster than threading `w through every call.
/ World[reg] — (re)create the singleton world from a component registry.
World: {[reg] wld:: `reg`sigs`archs`loc`filt!(reg; (); (); ()!(); ()!()); 0}

ecsCanon:   {[comps] c:?(),comps; c@<c}              / canonical comp set; (),x normalizes a lone `comp atom to a 1-vector
ecsProto:   {[reg;comps] $[#comps; ([id:0]),(,/reg@comps); [id:0]]}  / merged archetype prototype
dget:       {[d;k] (.d)@(!d)?k}                      / lookup in an int-keyed dict (@ is positional!)
wMatch:     {[sig;s] {[sig;x]x~sig}[sig]'s}          / per-element ~ mask against the sig list
wIdx:       {[m] w:&m; $[#w; *w; -1]}                / first true index of a mask, or -1
worldMatch: {[csig;sig] (#csig)=+/csig in sig}       / csig ⊆ sig  (subset test)

/ internal routing over the singleton `wld:
wFind:   {[sig] s:wld`sigs; $[0=#s; -1; wIdx wMatch[sig;s]]}      / archetype index for a sig, or -1
wMake:   {[sig] i:#wld`sigs; wld[`sigs]:: (wld`sigs),,sig; wld[`archs]:: (wld`archs),,Archetype ecsProto[wld`reg;sig]; i}
wEnsure: {[sig] i:wFind sig; $[i>-1; i; wMake sig]}  / index of the sig's archetype, creating it if new (i>-1, no >= in ink)
wSig:    {[eid] (wld`sigs)dget[wld`loc;eid]}         / an entity's current component set

/ Spawn[comps;vals] — spawn an entity with component set `comps and field values `vals
/ (a dict). Routes to the matching archetype, creating it if new. Returns the eid.
Spawn: {[comps;vals]
  i:wEnsure ecsCanon comps; eid:ecsId[];
  wld[`archs][i]:: aPush[(wld`archs)i; ([id:eid]),vals];
  wld[`loc][eid]:: i;
  eid}

/ Despawn[eid] — remove an entity entirely (drops its row from its archetype).
Despawn: {[eid]
  i:dget[wld`loc;eid];
  wld[`archs][i]:: ecsKill[(wld`archs)i; eid];
  wld[`loc]:: eid _ wld`loc;
  0}

/ wMoveTo[eid;nsig;vals] — relocate entity eid into the archetype for canonical signature
/ nsig (creating it if new), supplying any new fields in `vals. Internal to Endow/Divest.
wMoveTo: {[eid;nsig;vals]
  ci:dget[wld`loc;eid]; cArch:(wld`archs)ci;
  ni:wEnsure nsig;
  mv:ecsMove[cArch;(wld`archs)ni;eid;vals];
  wld[`archs][ci]:: mv 0;
  wld[`archs][ni]:: mv 1;
  wld[`loc][eid]:: ni;
  0}

/ Endow[eid;comp;vals] — add component `comp (its fields in `vals); the entity auto-moves
/ to the richer archetype. No-op if already present.
Endow: {[eid;comp;vals] csig:wSig eid; $[comp in csig; 0; wMoveTo[eid; ecsCanon csig,comp; vals]]}

/ Divest[eid;comp] — remove component `comp; the entity auto-moves to the sparser
/ archetype (the dropped fields vanish). No-op if the entity doesn't have comp.
Divest: {[eid;comp] csig:wSig eid; $[comp in csig; wMoveTo[eid; csig@&~csig in ,comp; ()!()]; 0]}

/ worldArch[comps] — the archetype (column-dict) for a component set, for reading.
/ Returns an empty archetype if that set isn't present.
worldArch:  {[comps] sig:ecsCanon comps; i:wFind sig; $[i>-1; (wld`archs)i; Archetype ecsProto[wld`reg;sig]]}
worldCount: {[comps] ecsCount worldArch comps}       / live entity count for a component set

/ Apply[comps;sys] — run system(s) on the SINGLE archetype for exactly `comps, in place.
/ No-op if that archetype isn't present. (Query is the cross-archetype/superset form.)
Apply: {[comps;sys] i:wFind ecsCanon comps; $[i>-1; wld[`archs][i]:: Tick[(wld`archs)i;sys]; 0]; 0}

/ ── cross-archetype query ───────────────────────────────────────────────────────
/ Query[comps;sys] — run system(s) `sys on EVERY archetype whose component set is a
/ superset of `comps, in place. This is how a movement system reaches all moving
/ entities at once whether they also carry Health, AI, … `sys must only touch columns
/ guaranteed by `comps (every match has those).
Query: {[comps;sys]
  csig:ecsCanon comps;
  m:{[csig;s]worldMatch[csig;s]}[csig]'wld`sigs;
  {[sys;i] wld[`archs][i]:: Tick[(wld`archs)i;sys]}[sys]'&m; 0}

/ Survey[comps;seed;f] — fold a reader f[acc;archetype] over every matching archetype
/ (acc seeded with `seed). Use for cross-archetype aggregates/counts.
Survey: {[comps;seed;f]
  csig:ecsCanon comps;
  m:{[csig;s]worldMatch[csig;s]}[csig]'wld`sigs;
  seed{[f;acc;i] f[acc;(wld`archs)i]}[f]/&m}

/ ── change-filtered query (Bevy's Changed<T>) ───────────────────────────────────
/ Watch[comps;watch;sys] — like Query, but runs `sys only on matching archetypes whose
/ `watch column changed since Watch last ran them, skipping the rest. The per-query
/ change state lives in wld`filt keyed by the `watch column (so watchers on different
/ columns don't clash). Use for consumers (build a render buffer, derive world
/ transforms) that should re-run only when their input dirtied. (epoch is never 0, so
/ 0 = "never seen".)
wRun:  {[filt;i;watch;sys] a2:Tick[(wld`archs)i;sys]; wld[`archs][i]:: a2; @[filt;i;:;epoch a2 watch]}
wStep: {[filt;i;watch;sys] arch:(wld`archs)i; cur:epoch arch watch; prev:$[i in !filt; dget[filt;i]; 0]; $[cur=prev; filt; wRun[filt;i;watch;sys]]}
Watch: {[comps;watch;sys]
  csig:ecsCanon comps;
  f0:$[watch in !wld`filt; dget[wld`filt;watch]; ()!()];
  m:{[csig;s]worldMatch[csig;s]}[csig]'wld`sigs;
  f1:f0{[watch;sys;acc;i] wStep[acc;i;watch;sys]}[watch;sys]/&m;
  wld[`filt][watch]:: f1;
  0}

/ ── GPU compute offload of archetype columns ────────────────────────────────────
/ Requires lib/gpu.k + lib/spirv.k loaded, and must run inside a gpuRun frame
/ (RunShader needs the active renderer). An archetype column is a flat f32 vector —
/ exactly a compute-shader buffer — so an element-wise system can run on the GPU.
/
/ ecsOffload[a;col;shader] — run a compiled element-wise compute `shader (the SPIR-V
/ from ComputeShader[{[x] ...}]) on column `col of archetype a, writing the result
/ back. Compile the shader ONCE and reuse it; this is just the per-frame dispatch.
ecsOffload: {[a;col;shader] @[a;col;:;RunShader[shader; a col]]}

/ ecsOffloadAll[a;cols;shaders] — offload several columns, each with its own shader.
/ `cols and `shaders are parallel lists. Returns the updated archetype.
ecsOffloadAll: {[a;cols;shaders] a{[cols;shaders;acc;k]ecsOffload[acc;cols k;shaders k]}[cols;shaders]/!#cols}

/ ecsOffload2[a;out;c1;c2;shader] — run a two-input element-wise compute `shader (from
/ ComputeShader2[{[x;y]...}]) on columns c1 and c2, writing the result into column `out.
/ This is true multi-column integration on the GPU, e.g. px += vx*dt:
/   ecsOffload2[a; `px; `px; `vx; ComputeShader2[{[px;vx] px+vx*0.016}]]
ecsOffload2: {[a;out;c1;c2;shader] @[a;out;:;RunShader2[shader; a c1; a c2]]}

/ ── hierarchy (apter tree) ──────────────────────────────────────────────────────
/ Cascade[par;local] — additive transform propagation over a parent-index column.
/ `par has self-loop roots (par[r]=r); `local is the per-node local value. Returns
/ world values: world[i] = local[i] + world[par[i]], roots = local. Nodes are
/ processed in increasing `depth order so each parent resolves before its children.
/ (For matrices, swap + for compose and gather the parent matrix.)
Cascade: {[par;local]
  ord:  <depth par
  prop: {[par;w;i] $[(par i)=i; w; @[w;i;:;((w i)+(w par i))]]}[par]
  local prop/ ord
}

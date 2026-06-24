/ lib/ecs.k — archetypal ECS, milestone 1 (pure data; no GPU required)
/
/ Each archetype is a dict of equal-length columns (scalar struct-of-arrays); the
/ `id column holds entity ids. There is no monolithic world — hold each archetype
/ in its own global (Movers::, Statics::, …) and thread it with `::`, the same way
/ the RunWindow frame loop threads state. Systems are plain functions
/ archetype -> archetype that operate on whole columns (the per-entity loop
/ disappears into array ops). Helpers are global (lambdas don't close over scope).
/
/ Hierarchy uses apter trees: a flat `par parent-index column + the `depth builtin
/ for level-batched transform propagation. Self-loop roots (par[r] = r).

/ ── entity ids ────────────────────────────────────────────────────────────────
ecsNxt:: 0
ecsId: {[] i:ecsNxt; ecsNxt::ecsNxt+1; i}            / fresh monotonic entity id

/ ── archetype construction ─────────────────────────────────────────────────────
/ ecsArch[proto] — empty archetype from a prototype row: a dict mapping each column
/ name to a sample value (establishes the column set AND each column's type).
/ Include `id in the proto. e.g. ecsArch `id`px`vx!(0;0.;0.)
ecsArch: {[proto] (!proto)!{0#x}'.proto}

/ ── spawn / despawn ─────────────────────────────────────────────────────────────
/ ecsSpawn[a;row] — append one entity. `row is a dict with a value for every column
/ of `a (including `id — use ecsId[] for a fresh one). Returns the new archetype.
ecsSpawn: {[a;row] (!a)!{[a;row;k]((a k),row k)}[a;row]'!a}

/ ecsWhere[a;mask] — the sub-archetype of rows where boolean `mask is true.
ecsWhere: {[a;mask] m:&mask; (!a)!{[a;m;k](a k)@m}[a;m]'!a}

/ ecsKill[a;eid] — remove the entity whose id = eid.
ecsKill: {[a;eid] ecsWhere[a; ~(a`id)=eid]}

/ ecsCount[a] — number of live entities.
ecsCount: {[a] #a`id}

/ ── archetype moves: component add / remove ─────────────────────────────────────
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
  (ecsWhere[src; ~(src`id)=eid]; ecsSpawn[dst; dstRow])}

/ ecsAddComp[src;dst;eid;vals] — add a component: move the entity to the richer
/ archetype dst, supplying the new fields in `vals (a dict). Returns (src2; dst2).
ecsAddComp: ecsMove

/ ecsRemoveComp[src;dst;eid] — remove a component: move the entity to the sparser
/ archetype dst (fewer columns; the dropped fields vanish). Returns (src2; dst2).
ecsRemoveComp: {[src;dst;eid] ecsMove[src;dst;eid;()!()]}

/ ── sparse-set side-tables (rare / optional / churny components) ─────────────────
/ A sparse component is a dict entityId!value — keyed by id, dense iteration via
/ !s (ids) / .s (values). Add/remove for one entity is cheap and does NOT move it
/ between archetypes, so use this for components that few entities have, or whose
/ membership changes often (Selected, Hovered, a timer…). Note: an int-keyed dict
/ indexes positionally with @, so lookups go through find: (.s)@(!s)?id.
ssetNew: {[] ()!()}                           / empty sparse set
ssetSet: {[s;eid;v] @[s;eid;:;v]}             / add or update entity eid's value
ssetDel: {[s;eid] eid _ s}                    / remove entity eid (no-op if absent)
ssetHas: {[s;eid] eid in !s}                  / does entity eid have the component?
ssetGet: {[s;eid;dflt] $[eid in !s; (.s)@(!s)?eid; dflt]}   / value or default

/ ssetMask[a;s] — boolean mask over archetype a's rows: which have the component.
ssetMask: {[a;s] (a`id) in !s}

/ ssetAlign[a;s;dflt] — the sparse value aligned to a's rows (dflt where absent), a
/ column usable directly in a system. Default-fill, then scatter present values in.
ssetAlign: {[a;s;dflt]
  ids:  a`id
  vals: (#ids)#dflt
  hit:  &ids in !s
  @[vals; hit; :; (.s)@((!s)?(ids@hit))]}

/ ── systems ─────────────────────────────────────────────────────────────────────
/ ecsRun[a;systems] — apply system(s), archetype -> archetype, left to right.
/ Pass a SINGLE system bare (ecsRun[a; sysMove]) or several as a list
/ (ecsRun[a; (sysMove;sysGrav;sysClamp)]). Do NOT enlist a single system with `,`
/ — `,fn corrupts the function to type `! (an ink bug, see doc/bug.md #7); pass it
/ bare instead, which this detects via `@.
ecsRun: {[a;systems] $[(@systems)~`func; systems a; a{[acc;s]s acc}/systems]}

/ ── command buffer ──────────────────────────────────────────────────────────────
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
  a: a{[acc;r]ecsSpawn[acc;r]}/ecsSpawnBuf
  ecsKillBuf:: 0#0; ecsSpawnBuf:: ()
  a}

/ ── stage scheduler (ordered system groups) ─────────────────────────────────────
/ A schedule is a dict stageName!systems, BUILT IN STAGE ORDER (the dict's key
/ order is the run order), e.g.  `update`cleanup!((sysMove;sysBoost); sysReap).
/ Each stage's value is a single system (bare) or a list of systems. schedRun runs
/ the stages in order, applying each stage's systems with ecsRun and flushing the
/ command buffer at the stage boundary — so a stage's deferred spawns/despawns are
/ visible to later stages (and applied before the frame ends).
schedRun: {[sched; a] a{[sched;acc;st] ecsFlush[ecsRun[acc; sched st]]}[sched]/!sched}

/ ── world: auto-routing archetype registry ──────────────────────────────────────
/ A "world" routes component add/remove by component-set SIGNATURE, so callers
/ never name src/dst archetypes. It is a dict [reg; sigs; archs; loc]:
/   reg   — component registry: compName -> field-prototype dict (field!sample), e.g.
/           `Position`Velocity!([px:0.;py:0.];[vx:0.;vy:0.])  (establishes columns+types)
/   sigs  — list of canonical component-sets present (sorted-distinct symbol vectors)
/   archs — list of archetypes (column-dicts), parallel to sigs
/   loc   — dict entityId -> index into sigs/archs (which archetype it is in)
worldNew: {[reg] `reg`sigs`archs`loc!(reg; (); (); ()!())}

ecsCanon: {[comps] c:?comps; c@<c}                  / canonical (sorted-distinct) comp set
ecsProto: {[reg;comps] $[#comps; ([id:0]),(,/reg@comps); [id:0]]}  / merged archetype prototype
dget:     {[d;k] (.d)@(!d)?k}                        / lookup in an int-keyed dict (@ is positional!)
wMatch:   {[sig;s] {[sig;x]x~sig}[sig]'s}            / per-element ~ mask against the sig list
wIdx:     {[m] w:&m; $[#w; *w; -1]}                  / first true index of a mask, or -1
wFind:    {[w;sig] s:w`sigs; $[0=#s; -1; wIdx wMatch[sig;s]]}     / archetype index for a sig, or -1
wMake:    {[w;sig] a:ecsArch ecsProto[w`reg;sig]; i:#w`sigs; w:@[w;`sigs;:;(w`sigs),,sig]; w:@[w;`archs;:;(w`archs),,a]; (w;i)}
wEnsure:  {[w;sig] i:wFind[w;sig]; $[i>-1; (w;i); wMake[w;sig]]}  / NB: i>-1, NOT i>=0 (no >= in ink)
wSig:     {[w;eid] (w`sigs)dget[w`loc;eid]}          / an entity's current component set

/ worldSpawn[w;comps;vals] — spawn an entity with component set `comps` and field
/ values `vals (a dict). Routes to the matching archetype, creating it if new. (w; eid).
worldSpawn: {[w;comps;vals] sig:ecsCanon comps; r:wEnsure[w;sig]; w:r 0; i:r 1; eid:ecsId[]; a2:ecsSpawn[(w`archs)i; ([id:eid]),vals]; w:@[w;`archs;:;@[w`archs;i;:;a2]]; w:@[w;`loc;:;@[w`loc;eid;:;i]]; (w;eid)}

/ wMoveTo[w;eid;nsig;vals] — relocate entity eid into the archetype for canonical
/ signature nsig (creating it if new), supplying any new fields in `vals.
wMoveTo: {[w;eid;nsig;vals] ci:dget[w`loc;eid]; cArch:(w`archs)ci; r:wEnsure[w;nsig]; w:r 0; ni:r 1; mv:ecsMove[cArch;(w`archs)ni;eid;vals]; w:@[w;`archs;:;@[@[w`archs;ci;:;mv 0];ni;:;mv 1]]; @[w;`loc;:;@[w`loc;eid;:;ni]]}

/ addComponent[w;eid;comp;vals] — add component `comp` (its fields in `vals`); the
/ entity auto-moves to the archetype with its components + comp. No-op if already present.
wAddDo: {[w;eid;comp;vals] csig:wSig[w;eid]; wMoveTo[w;eid; ecsCanon csig,comp; vals]}
addComponent: {[w;eid;comp;vals] $[comp in wSig[w;eid]; w; wAddDo[w;eid;comp;vals]]}

/ removeComponent[w;eid;comp] — remove `comp`; the entity auto-moves to the sparser
/ archetype (the dropped fields vanish). No-op if the entity doesn't have comp.
wRemDo: {[w;eid;comp] csig:wSig[w;eid]; wMoveTo[w;eid; csig@&~csig in ,comp; ()!()]}
removeComponent: {[w;eid;comp] $[~comp in wSig[w;eid]; w; wRemDo[w;eid;comp]]}

/ worldArch[w;comps] — the archetype (column-dict) for a component set, for systems and
/ queries. Returns an empty archetype if that set isn't present.
worldArch: {[w;comps] sig:ecsCanon comps; i:wFind[w;sig]; $[i>-1; (w`archs)i; ecsArch ecsProto[w`reg;sig]]}

/ worldApply[w;comps;sys] — run system(s) on the archetype for component set `comps`
/ and write the result back into the world. No-op if that archetype isn't present.
worldApply: {[w;comps;sys] sig:ecsCanon comps; i:wFind[w;sig]; $[i>-1; @[w;`archs;:;@[w`archs;i;:;ecsRun[(w`archs)i;sys]]]; w]}

/ worldCount[w;comps] — number of live entities in the archetype for `comps.
worldCount: {[w;comps] ecsCount worldArch[w;comps]}

/ ── cross-archetype query ───────────────────────────────────────────────────────
/ worldQuery[w;comps;sys] — run system(s) `sys on EVERY archetype whose component
/ set is a superset of `comps, regardless of the other components those archetypes
/ carry. This is how a movement system reaches all moving entities at once whether
/ they also have Health, AI, … Each matching archetype is updated in place.
/ `sys must only touch columns guaranteed by `comps (every match has those).
worldMatch: {[csig;sig] (#csig)=+/csig in sig}      / csig ⊆ sig  (subset test)
worldQuery: {[w;comps;sys]
  csig: ecsCanon comps
  m:    {[csig;s]worldMatch[csig;s]}[csig]'w`sigs   / which archetypes are supersets
  idxs: &m
  w{[sys;acc;i] @[acc;`archs;:;@[acc`archs;i;:;ecsRun[(acc`archs)i;sys]]]}[sys]/idxs}

/ worldEach[w;comps;f] — fold a reader f[acc;archetype] over every matching archetype
/ (acc seeded with the 2nd-to-last arg). Use for cross-archetype aggregates/counts.
worldEach: {[w;comps;seed;f] csig:ecsCanon comps; m:{[csig;s]worldMatch[csig;s]}[csig]'w`sigs; seed{[w;f;acc;i] f[acc;(w`archs)i]}[w;f]/&m}

/ ── hierarchy (apter tree) ──────────────────────────────────────────────────────
/ ecsPropagate[par;local] — additive transform propagation over a parent-index
/ column. `par has self-loop roots (par[r]=r); `local is the per-node local value.
/ Returns world values: world[i] = local[i] + world[par[i]], roots = local. Nodes
/ are processed in increasing `depth order so each parent resolves before its
/ children. (For matrices, swap + for compose and gather the parent matrix.)
ecsPropagate: {[par;local]
  ord:  <depth par
  prop: {[par;w;i] $[(par i)=i; w; @[w;i;:;((w i)+(w par i))]]}[par]
  local prop/ ord}

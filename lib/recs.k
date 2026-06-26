/ lib/recs.k — a relational ECS. An archetype is a TABLE [[]id:…;cols…]; an entity is a
/ row keyed by `id. Now that tables support amend, left/outer join and row append, almost
/ every ECS operation IS a native table operator — so this module is tiny. It just mints
/ entity ids and names the common patterns:
/
/   spawn    Spawn[a;vals]     a,(`id!Id[]),vals    append a row (fresh id)
/   despawn  Despawn[a;e]      a@&~(a`id)=e          remove an entity
/   system   @[a;`c;:;expr]    (native amend)        whole-column update — no per-entity loop
/   pipeline Tick[a;systems]   a{y x}/systems        run system(s) left to right
/   query    Where[a;mask]     a@&mask               sub-table of matching rows
/   lookup   Get[a;e]          a@&(a`id)=e           an entity's row
/   sparse   a,k               (native left join)    attach a keyed component, 0-filled
/   merge    k1,k2             (native outer join)   combine two keyed tables

Nxt:: 0
Id: {[] i:Nxt; Nxt::Nxt+1; i}                  / fresh monotonic entity id

/ Spawn[a;vals] — append an entity to table a. `vals is a dict of the NON-id columns; a
/ fresh `id is generated and prepended (dict-merge), then the row is inserted.
Spawn: {[a;vals] a,(`id!Id[]),vals}

/ Despawn[a;e] — remove the entity whose id = e.
Despawn: {[a;e] a@&~(a`id)=e}

/ Get[a;e] — the entity's row as a 1-row table (empty if absent).
Get: {[a;e] a@&(a`id)=e}

/ Where[a;mask] — the sub-table of rows where boolean mask is true (a query/filter).
Where: {[a;mask] a@&mask}

/ Count[a] — number of live entities (rows).
Count: {[a] #a}

/ Tick[a;systems] — thread a table through system(s) (table -> table), left to right.
/ A system is a whole-column op like {[a] @[a;`px;:;(a`px)+a`vx]}.
Tick: {[a;systems] a{y x}/systems}

/ ── keyed-table (utable) archetype: id is the KEY ───────────────────────────────
/ An alternative storage where the archetype is a KEYED table [[id:…]cols…]. Entities
/ are deduped by id, lookup is direct (w@e), and despawn drops the key. Systems are the
/ SAME native amend (@[w;`px;:;…] updates the value column; w`px reads it). Use this when
/ you want id-keyed access; use the plain-table form above when you want a dense scan.
KSpawn:   {[w;vals] w,(`id!Id[]),vals}     / upsert a fresh entity (a row with a new id)
KDespawn: {[w;e] e _ w}                     / drop the entity (or entities, if e is a vector)
KGet:     {[w;e] w@e}                       / entity e's value row (empty if absent)
KSet:     {[w;e;vals] w[e]:vals; w}         / set/insert entity e's value row (upsert by key)

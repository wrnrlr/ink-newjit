/ test/recs.k — the relational/table ECS (lib/recs.k). Everything the archetype ECS did —
/ spawn, systems, despawn, query, sparse components, hierarchy — but an archetype is a
/ plain TABLE and the operations are native table operators (amend / join / row-select).
/   ./zig-out/bin/ink test/recs.k

2: "lib/recs.k"

/ a "Movers" archetype: id + 2D position + velocity, as an empty TYPED table
Movers:: [[]id:!0;px:0#0.;py:0#0.;vx:0#0.;vy:0#0.]

/ spawn three entities (fresh ids minted by Spawn)
Movers:: Spawn[Movers; `px`py`vx`vy!(0.;0.; 1.;0.)]
Movers:: Spawn[Movers; `px`py`vx`vy!(5.;5.; 0.;1.)]
Movers:: Spawn[Movers; `px`py`vx`vy!(9.;0.;-1.;0.)]
`0 0: "spawned 3:"
`0 0: $Movers

/ systems are whole-column ops (no per-entity loop). Multi-column read `x`px`py` returns
/ the columns as a LIST, so `(x`px`py)+x`vx`vy` adds them positionally (px+vx, py+vy); the
/ bare amend `@[x;cols;:;…]` writes them back and (being an expression) returns the table.
sysMove:  {@[x;`px`py;:;(x`px`py)+x`vx`vy]}
sysFloor: {@[x;`py;:;0.|x`py]}

Movers:: Movers{y x}/systems Tick[Movers; (sysMove;sysFloor)]
`0 0: "after Tick (sysMove;sysFloor):"
`0 0: $Movers

/ query: a sub-table of entities moving right (vx>0)
`0 0: "query Where vx>0:"
`0 0: $Where[Movers; (Movers`vx)>0.]

/ lookup one entity's row by id
`0 0: "Get entity 2:"
`0 0: $Get[Movers; 2]

/ despawn entity 1
Movers:: Despawn[Movers; 1]
`0 0: "after Despawn 1:"
`0 0: $Movers

/ ── sparse component via native LEFT JOIN ───────────────────────────────────────
/ a Boost on just entities 0 and 2 — a keyed table; the join 0-fills entities without it
Boost:: [[id:0 2]boost:100. 50.]
J:: Movers,Boost
`0 0: "Movers left-joined with sparse Boost (0 where absent):"
`0 0: $J
`0 0: "apply the boost to px in one column op:"
`0 0: $@[J;`px;:;(J`px)+J`boost]

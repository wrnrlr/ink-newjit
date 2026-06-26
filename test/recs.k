/ test/recs.k — the relational/table ECS (lib/recs.k). Everything the archetype ECS did —
/ spawn, systems, despawn, query, sparse components, hierarchy — but an archetype is a
/ plain TABLE and the operations are native table operators (amend / join / row-select).
/   ./zig-out/bin/ink test/recs.k

2: "lib/recs.k"

seq::0;ID:{seq+::1;seq}
Particles:[[]id:!0;px:0#0.;py:0#0.;vx:0#0.;vy:0#0.] / a "Particle" archetype: id + 2D position + velocity, as an empty TYPED table
Particle:`id`px`py`vx`vy
Particles,:Particle!(Id();0.;0.;1.;0.) / spawn 2 entities
/ Particles,:Particle!((Id();5.;5.;0.;0.) / spawn 2 entities
/                      (Id();9.;0.;-1.;0.));
`0 0: "spawned 3:"
`0 0: $Particles

/ systems are whole-column ops (no per-entity loop). Multi-column read `x`px`py` returns
/ the columns as a LIST, so `(x`px`py)+x`vx`vy` adds them positionally (px+vx, py+vy); the
/ bare amend `@[x;cols;:;…]` writes them back and (being an expression) returns the table.
move:  {@[x;`px`py;:;(x`px`py)+x`vx`vy]}
groundfloor: {@[x;`py;:;0.|x`py]}

Particles:: Particles {y x}/(move;groundfloor)
`0 0: "after Tick (move;groundfloor):"
`0 0: $Particles

/ query: a sub-table of entities moving righ t (vx>0)
`0 0: "query Where vx>0:"
QueryParticle: {x@x&y}[Particle];
MovingRight: {&(x`vx)>0}
`0 0: QueryParticle MovingRight

/ lookup one entity's row by id
`0 0: "Get entity 2:"
`0 0: $Get[Particles; 2]

/ despawn entity 1
Particles:: Despawn[Particles; 1]
`0 0: "after Despawn 1:"
`0 0: $Particles

/ ── sparse component via native LEFT JOIN ───────────────────────────────────────
/ a Boost on just entities 0 and 2 — a keyed table; the join 0-fills entities without it
Boost:: [[id:0 2]boost:100. 50.]
J:: Particles,Boost
`0 0: "Particle left-joined with sparse Boost (0 where absent):"
`0 0: $J
`0 0: "apply the boost to px in one column op:"
`0 0: $@[J;`px;:;(J`px)+J`boost]

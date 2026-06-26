/ test/recs_keyed.k — the relational ECS with a KEYED-TABLE archetype (a utable). The
/ archetype is [[id:…]cols…]: entities are keyed by id, so spawn upserts (dedup by id),
/ lookup is direct (W@id), and despawn drops the key. Systems are the same native amend.
/   ./zig-out/bin/ink test/recs_keyed.k

2: "lib/recs.k"

/ a keyed "Movers" archetype: id is the key; px/py/vx/vy are value columns
Movers:: [[id:!0]px:0#0.;py:0#0.;vx:0#0.;vy:0#0.]

/ spawn three entities — KSpawn upserts a row with a fresh id
Movers:: KSpawn[Movers; `px`py`vx`vy!(0.;0.; 1.;0.)]
Movers:: KSpawn[Movers; `px`py`vx`vy!(5.;5.; 0.;1.)]
Movers:: KSpawn[Movers; `px`py`vx`vy!(9.;0.;-1.;0.)]
`0 0: "spawned 3 (keyed by id):"
`0 0: $Movers

/ systems: whole-column amend — w`px reads a value column, @[w;`px;:;…] writes it
sysMove:  {[w] w:@[w;`px;:;(w`px)+w`vx]; @[w;`py;:;(w`py)+w`vy]}
sysFloor: {[w] @[w;`py;:;0.|w`py]}
Movers:: Tick[Movers; (sysMove;sysFloor)]
`0 0: "after Tick (sysMove;sysFloor):"
`0 0: $Movers

/ direct lookup by id (no scan in the source — W@id)
`0 0: "KGet entity 1:"
`0 0: $KGet[Movers; 1]

/ despawn entity 1 by dropping its key
Movers:: KDespawn[Movers; 1]
`0 0: "after KDespawn 1:"
`0 0: $Movers

/ re-spawning reuses the upsert path; ids stay unique
Movers:: KSpawn[Movers; `px`py`vx`vy!(2.;2.;0.;0.)]
`0 0: "after spawning a 4th entity:"
`0 0: $Movers

/ set an entity's value row by id — the `w[key]:valrow` upsert sugar (replace entity 0)
Movers:: KSet[Movers; 0; `px`py`vx`vy!(100.;100.;0.;0.)]
`0 0: "after KSet 0 (upsert by key via Movers[0]:row):"
`0 0: $Movers

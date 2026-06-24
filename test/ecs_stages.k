/ test/ecs_stages.k — sparse-set side-tables + ordered stage scheduler.
/ Headless / pure data.   ./zig-out/bin/ink test/ecs_stages.k

2: "lib/ecs.k"

/ dense archetype: id + position + velocity
World:: ecsArch `id`px`vx!(0;0.;0.)
World:: ecsSpawn[World; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 0
World:: ecsSpawn[World; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 1
World:: ecsSpawn[World; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 2
World:: ecsSpawn[World; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 3

/ a RARE component "Boost" on just entities 1 and 3 — stored sparse, not in the
/ archetype (so the other entities don't carry a dead column).
Boost:: ssetNew[]
Boost:: ssetSet[Boost; 1; 5.]
Boost:: ssetSet[Boost; 3; 10.]

/ ── systems ─────────────────────────────────────────────────────────────────────
sysMove:  {[a] @[a;`px;:;(a`px)+a`vx]}                       / dense: px += vx
sysBoost: {[a] @[a;`px;:;(a`px)+ssetAlign[a;Boost;0.]]}      / sparse join: boosted get extra
reapEach: {[a;i] ecsCmdKill[(a`id)i]}
sysReap:  {[a] reapEach[a]'&(a`px)>8.; a}                    / enqueue despawn for px>8 (deferred)

/ ── schedule: stages run in key order; command buffer flushes at each boundary ──
sched: `update`cleanup!((sysMove; sysBoost); sysReap)

showFrame: {[k] `0 0: $`frame`ids`px!(k; World`id; World`px)}

`0 0: "Boost (sparse, ids 1 & 3):"
`0 0: $Boost
showFrame 0

World:: schedRun[sched; World]
showFrame 1
World:: schedRun[sched; World]
showFrame 2
World:: schedRun[sched; World]
showFrame 3

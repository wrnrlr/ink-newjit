/ test/ecs_stages.k — sparse-set side-tables + ordered stage scheduler.
/ Headless / pure data.   ./zig-out/bin/ink test/ecs_stages.k

2: "lib/ecs.k"

/ dense archetype: id + position + velocity
Bodies:: Archetype `id`px`vx!(0;0.;0.)
Bodies:: aPush[Bodies; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 0
Bodies:: aPush[Bodies; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 1
Bodies:: aPush[Bodies; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 2
Bodies:: aPush[Bodies; `id`px`vx!(ecsId[]; 0.; 1.)]   / id 3

/ a RARE component "Boost" on just entities 1 and 3 — stored sparse, not in the
/ archetype (so the other entities don't carry a dead column).
Boost:: []
Boost[1]::5.
Boost[3]::10.

/ ── systems ─────────────────────────────────────────────────────────────────────
sysMove:  {[a] @[a;`px;:;(a`px)+a`vx]}                       / dense: px += vx
sysBoost: {[a] @[a;`px;:;(a`px)+ssetAlign[a;Boost;0.]]}      / sparse join: boosted get extra
reapEach: {[a;i] ecsCmdKill[(a`id)i]}
sysReap:  {[a] reapEach[a]'&(a`px)>8.; a}                    / enqueue despawn for px>8 (deferred)

/ ── schedule: stages run in key order; command buffer flushes at each boundary ──
sched: `update`cleanup!((sysMove; sysBoost); sysReap)

showFrame: {[k] `0 0: $`frame`ids`px!(k; Bodies`id; Bodies`px)}

`0 0: "Boost (sparse, ids 1 & 3):"
`0 0: $Boost
showFrame 0

Bodies:: schedRun[sched; Bodies]
showFrame 1
Bodies:: schedRun[sched; Bodies]
showFrame 2
Bodies:: schedRun[sched; Bodies]
showFrame 3

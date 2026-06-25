/ test/ecs.k — exercise the archetypal ECS (headless, pure data).
/   ./zig-out/bin/ink test/ecs.k

2: "lib/ecs.k"

/ A "movers" archetype: id + 2D position + 2D velocity.
Movers:: Archetype `id`px`py`vx`vy!(0;0.;0.;0.;0.)

/ spawn three entities (fresh ids from ecsId[])
Movers:: aPush[Movers; `id`px`py`vx`vy!(ecsId[]; 0.; 0.;  1.; 0.)]
Movers:: aPush[Movers; `id`px`py`vx`vy!(ecsId[]; 5.; 5.;  0.; 1.)]
Movers:: aPush[Movers; `id`px`py`vx`vy!(ecsId[]; 9.; 0.; -1.; 0.)]
`0 0: "spawned (3):"
`0 0: $Movers

/ systems: integrate position by velocity, then clamp py to a floor at 0.
sysMove:  {[a] dt:1.; a:@[a;`px;:;(a`px)+dt*a`vx]; @[a;`py;:;(a`py)+dt*a`vy]}
sysFloor: {[a] @[a;`py;:;0.|a`py]}
Movers:: Tick[Movers; (sysMove; sysFloor)]
`0 0: "after (sysMove;sysFloor):"
`0 0: $Movers

/ query: live count, and a filtered view (entities still at the origin row 0)
`0 0: "count:"
`0 0: $ecsCount Movers

/ despawn entity id 1
Movers:: ecsKill[Movers; 1]
`0 0: "after kill id 1:"
`0 0: $Movers

/ ── hierarchy (apter tree) ──────────────────────────────────────────────────────
/ par: node0 root; 1,2 children of 0/1; tree 0<-1<-{2,3}, 0<-1, 2<-4
par:   0 0 1 1 2
local: 10. 1. 2. 3. 4.
`0 0: "depth (expect 0 1 2 2 3):"
`0 0: $depth par
`0 0: "world propagate (expect 10 11 13 14 17):"
`0 0: $Cascade[par; local]

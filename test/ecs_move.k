/ test/ecs_move.k — multi-archetype: component add/remove moves a row between
/ archetypes (the defining archetypal-ECS operation). Headless / pure data.
/   ./zig-out/bin/ink test/ecs_move.k

2: "lib/ecs.k"

/ Two archetypes for the same entities, distinguished by their component set:
/   Static : id, px, py            (a placed thing)
/   Moving : id, px, py, vx, vy    (Static + a Velocity component)
Static:: ecsArch `id`px`py!(0;0.;0.)
Moving:: ecsArch `id`px`py`vx`vy!(0;0.;0.;0.;0.)

/ spawn entity `e in Static
e:: ecsId[]
Static:: ecsSpawn[Static; `id`px`py!(e; 3.; 4.)]
`0 0: "spawned in Static:"
`0 0: $Static

/ ── add a Velocity component → e moves Static → Moving (supply vx,vy) ───────────
r::ecsAddComp[Static; Moving; e; `vx`vy!(1.; 2.)]
Static:: r 0
Moving:: r 1
`0 0: "after add Velocity — Static (now empty), Moving (px,py carried + vx,vy):"
`0 0: $Static
`0 0: $Moving

/ run a movement system on Moving (whole-column)
sysMove: {[a] a:@[a;`px;:;(a`px)+a`vx]; @[a;`py;:;(a`py)+a`vy]}
sysMove: {[a] a:@[a;`px`py;:;((a`px)+a`vx;(a`py)+a`vy)];
Moving:: ecsRun[Moving; sysMove]
`0 0: "after sysMove on Moving (px+=vx, py+=vy):"
`0 0: $Moving

/ ── remove the Velocity component → e moves Moving → Static (vx,vy dropped) ──────
r2::     ecsRemoveComp[Moving; Static; e]
Moving:: r2 0
Static:: r2 1
`0 0: "after remove Velocity — Moving (empty), Static (updated px,py, no vx,vy):"
`0 0: $Moving
`0 0: $Static

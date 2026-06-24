/ test/ecs_query.k — cross-archetype queries: a system runs over EVERY archetype
/ that has the required components, regardless of what else those entities carry.
/ Headless / pure data.   ./zig-out/bin/ink test/ecs_query.k

2: "lib/ecs.k"

reg: `Position`Velocity`Health!([px:0.;py:0.];[vx:0.;vy:0.];[hp:100])
W:: worldNew reg

/ three entities in three different archetypes:
/   moving         : Position + Velocity
/   moving + alive : Position + Velocity + Health
/   static         : Position only (NO Velocity)
r:: worldSpawn[W; `Position`Velocity;        [px:0.; py:0.; vx:1.; vy:2.]];          W:: r 0
r:: worldSpawn[W; `Position`Velocity`Health; [px:10.;py:10.;vx:3.; vy:4.; hp:50]];   W:: r 0
r:: worldSpawn[W; ,`Position;                [px:99.;py:99.]];                       W:: r 0

`0 0: "before — Pos+Vel | Pos+Vel+Health | Position-only:"
`0 0: $worldArch[W; `Position`Velocity]
`0 0: $worldArch[W; `Position`Velocity`Health]
`0 0: $worldArch[W; ,`Position]

/ ── cross-archetype movement: every archetype with Position+Velocity gets moved ─
sysMove: {[a] a:@[a;`px;:;(a`px)+a`vx]; @[a;`py;:;(a`py)+a`vy]}
W:: worldQuery[W; `Position`Velocity; sysMove]

`0 0: "after worldQuery sysMove — both moving archetypes advance; static unchanged:"
`0 0: $worldArch[W; `Position`Velocity]            / px 0->1, py 0->2
`0 0: $worldArch[W; `Position`Velocity`Health]     / px 10->13, py 10->14
`0 0: $worldArch[W; ,`Position]                    / 99,99 unchanged (no Velocity)

/ ── cross-archetype aggregate: count every moving entity across all archetypes ──
moving:: worldEach[W; `Position`Velocity; 0; {[acc;a] acc+ecsCount a}]
`0 0: "total moving entities (summed across all matching archetypes):"
`0 0: $moving

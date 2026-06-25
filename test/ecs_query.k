/ test/ecs_query.k — cross-archetype queries: a system runs over EVERY archetype
/ that has the required components, regardless of what else those entities carry.
/ Headless / pure data.   ./zig-out/bin/ink test/ecs_query.k

2: "lib/ecs.k"

z: World[`Position`Velocity`Health!([px:0.;py:0.];[vx:0.;vy:0.];[hp:100])]

/ three entities in three different archetypes:
/   moving         : Position + Velocity
/   moving + alive : Position + Velocity + Health
/   static         : Position only (NO Velocity)
z: Spawn[`Position`Velocity;        [px:0.; py:0.; vx:1.; vy:2.]]
z: Spawn[`Position`Velocity`Health; [px:10.;py:10.;vx:3.; vy:4.; hp:50]]
z: Spawn[,`Position;                [px:99.;py:99.]]

`0 0: "before — Pos+Vel | Pos+Vel+Health | Position-only:"
`0 0: $worldArch[`Position`Velocity]
`0 0: $worldArch[`Position`Velocity`Health]
`0 0: $worldArch[,`Position]

/ ── cross-archetype movement: every archetype with Position+Velocity gets moved ─
sysMove: {[a] a:@[a;`px;:;(a`px)+a`vx]; @[a;`py;:;(a`py)+a`vy]}
z: Query[`Position`Velocity; sysMove]

`0 0: "after Query sysMove — both moving archetypes advance; static unchanged:"
`0 0: $worldArch[`Position`Velocity]            / px 0->1, py 0->2
`0 0: $worldArch[`Position`Velocity`Health]     / px 10->13, py 10->14
`0 0: $worldArch[,`Position]                    / 99,99 unchanged (no Velocity)

/ ── cross-archetype aggregate: count every moving entity across all archetypes ──
moving: Survey[`Position`Velocity; 0; {[acc;a] acc+ecsCount a}]
`0 0: "total moving entities (summed across all matching archetypes):"
`0 0: $moving

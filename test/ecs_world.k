/ test/ecs_world.k — the singleton World: add/remove components by signature, so the
/ caller never names src/dst archetypes and never threads a world value. Headless.
/   ./zig-out/bin/ink test/ecs_world.k

2: "lib/ecs.k"

/ component registry: name -> field prototype (establishes columns + types)
z: World[`Position`Velocity`Health!([px:0.;py:0.];[vx:0.;vy:0.];[hp:100])]

/ spawn three entities with different component sets; a & c share an archetype
a: Spawn[,`Position;          [px:1.;py:1.]]
b: Spawn[`Position`Velocity;  [px:2.;py:2.;vx:1.;vy:0.]]
c: Spawn[,`Position;          [px:3.;py:3.]]

show: {[lbl] `0 0: lbl; `0 0: $`Position`PosVel!(worldCount[,`Position]; worldCount[`Position`Velocity])}
show "spawned a,c=Position  b=Pos+Vel  (counts Position / Pos+Vel):"

/ ── add Velocity to a → it auto-moves Position → Pos+Vel (joins b) ──────────────
z: Endow[a; `Velocity; [vx:5.;vy:5.]]
show "after Endow a Velocity:"
`0 0: "Pos+Vel archetype now:"
`0 0: $worldArch[`Position`Velocity]

/ ── run a movement system on exactly the Pos+Vel archetype (Apply = exact match) ─
sysMove: {[arch] arch:@[arch;`px;:;(arch`px)+arch`vx]; @[arch;`py;:;(arch`py)+arch`vy]}
z: Apply[`Position`Velocity; sysMove]
`0 0: "after Apply sysMove on Pos+Vel:"
`0 0: $worldArch[`Position`Velocity]

/ ── remove Velocity from a → it auto-moves back to Position (vx,vy dropped) ──────
z: Divest[a; `Velocity]
show "after Divest a Velocity:"
`0 0: "Position archetype now (a back, with moved px,py; plus c):"
`0 0: $worldArch[,`Position]

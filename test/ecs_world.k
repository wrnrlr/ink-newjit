/ test/ecs_world.k — auto-routing world: add/remove components by signature, so the
/ caller never names src/dst archetypes. Headless / pure data.
/   ./zig-out/bin/ink test/ecs_world.k

2: "lib/ecs.k"

/ component registry: name -> field prototype (establishes columns + types)
reg: `Position`Velocity`Health!([px:0.;py:0.];[vx:0.;vy:0.];[hp:100])
W:: worldNew reg

/ spawn three entities with different component sets; a & c share an archetype
r:: worldSpawn[W; ,`Position;          [px:1.;py:1.]];               W:: r 0; a:: r 1
r:: worldSpawn[W; `Position`Velocity;  [px:2.;py:2.;vx:1.;vy:0.]];  W:: r 0; b:: r 1
r:: worldSpawn[W; ,`Position;          [px:3.;py:3.]];              W:: r 0; c:: r 1

show: {[lbl] `0 0: lbl; `0 0: $`Position`PosVel!(worldCount[W;,`Position]; worldCount[W;`Position`Velocity])}
show "spawned a,c=Position  b=Pos+Vel  (counts Position / Pos+Vel):"

/ ── add Velocity to a → it auto-moves Position → Pos+Vel (joins b) ──────────────
W:: addComponent[W; a; `Velocity; [vx:5.;vy:5.]]
show "after addComponent a Velocity:"
`0 0: "Pos+Vel archetype now:"
`0 0: $worldArch[W; `Position`Velocity]

/ ── run a movement system on the Pos+Vel archetype, written back into the world ──
sysMove: {[arch] arch:@[arch;`px;:;(arch`px)+arch`vx]; @[arch;`py;:;(arch`py)+arch`vy]}
W:: worldApply[W; `Position`Velocity; sysMove]
`0 0: "after worldApply sysMove on Pos+Vel:"
`0 0: $worldArch[W; `Position`Velocity]

/ ── remove Velocity from a → it auto-moves back to Position (vx,vy dropped) ──────
W:: removeComponent[W; a; `Velocity]
show "after removeComponent a Velocity:"
`0 0: "Position archetype now (a back, with moved px,py; plus c):"
`0 0: $worldArch[W; ,`Position]

/ test/ecs_changed.k — change-filtered queries (Bevy's Changed<T>). A consumer
/ system re-runs only on archetypes whose watched column dirtied since last time.
/ Watch keeps its per-column change state inside the singleton world. Headless.
/   ./zig-out/bin/ink test/ecs_changed.k

2: "lib/ecs.k"

z: World[`Position`Velocity`Health!([px:0.;py:0.];[vx:1.;vy:0.];[hp:100])]
/ two archetypes that both match Position+Velocity
z: Spawn[`Position`Velocity;        [px:0.; py:0.; vx:1.; vy:0.]]
z: Spawn[`Position`Velocity`Health; [px:5.; py:0.; vx:1.; vy:0.; hp:50]]

/ a read-only "render-prep" consumer: counts how often it actually runs
gRuns:: 0
deriveSys: {[a] gRuns:: gRuns+1; a}
sysMove:   {[a] @[a;`px;:;(a`px)+a`vx]}

step: {[lbl] Watch[`Position`Velocity; `px; deriveSys]; `0 0: lbl; `0 0: $`runs!gRuns}

step "frame 1 — both archetypes fresh, both derive (expect runs:2):"
step "frame 2 — nothing moved, both skip (expect runs:2):"

/ move ONLY the Pos+Vel archetype (exact-match Apply), dirtying its px
z: Apply[`Position`Velocity; sysMove]
step "frame 3 — moved Pos+Vel only; just it re-derives (expect runs:3):"

step "frame 4 — nothing moved, both skip again (expect runs:3):"

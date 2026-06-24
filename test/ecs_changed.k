/ test/ecs_changed.k — change-filtered queries (Bevy's Changed<T>). A consumer
/ system re-runs only on archetypes whose watched column dirtied since last time.
/ Headless / pure data.   ./zig-out/bin/ink test/ecs_changed.k

2: "lib/ecs.k"

reg: `Position`Velocity`Health!([px:0.;py:0.];[vx:1.;vy:0.];[hp:100])
W:: worldNew reg
/ two archetypes that both match Position+Velocity
r:: worldSpawn[W; `Position`Velocity;        [px:0.; py:0.; vx:1.; vy:0.]];        W:: r 0
r:: worldSpawn[W; `Position`Velocity`Health; [px:5.; py:0.; vx:1.; vy:0.; hp:50]]; W:: r 0

/ a read-only "render-prep" consumer: counts how often it actually runs
gRuns:: 0
deriveSys: {[a] gRuns:: gRuns+1; a}
filt::     ()!()                               / per-query change-filter state
sysMove:   {[a] @[a;`px;:;(a`px)+a`vx]}

step: {[lbl] r:worldQueryChanged[W; filt; `Position`Velocity; `px; deriveSys]; W::r 0; filt::r 1; `0 0: lbl; `0 0: $`runs!gRuns}

step "frame 1 — both archetypes fresh, both derive (expect runs:2):"
step "frame 2 — nothing moved, both skip (expect runs:2):"

/ move ONLY the Pos+Vel archetype (exact-match worldApply), dirtying its px
W:: worldApply[W; `Position`Velocity; sysMove]
step "frame 3 — moved Pos+Vel only; just it re-derives (expect runs:3):"

step "frame 4 — nothing moved, both skip again (expect runs:3):"

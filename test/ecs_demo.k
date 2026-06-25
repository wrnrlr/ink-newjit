/ test/ecs_demo.k — a runnable ECS particle fountain.
/
/ Ties the whole slice together in a RunWindow frame loop:
/   1. systems run as whole-column ops over an archetype
/   2. structural change (spawn/despawn) is deferred through the command buffer
/      and flushed once at the frame boundary
/   3. change detection (the `epoch verb) rebuilds a render buffer only when its
/      source data dirtied — the dynamic particle buffer rebuilds every frame, the
/      static background is built once and skipped thereafter
/   4. each render layer is one batched FillFrame
/
/   timeout 6s ./zig-out/bin/ink test/ecs_demo.k    (opens a window; prints diagnostics)

2: "lib/gpu.k"
2: "lib/ecs.k"

/ ── archetype: particles (id + 2D position, velocity, life) ─────────────────────
Particles:: Archetype `id`px`py`vx`vy`life!(0;0.;0.;0.;0.;0.)

/ ── sim parameters ──────────────────────────────────────────────────────────────
gDt:: 0.016; gGrav:: 220.

/ ── systems (each operates on whole columns; no per-entity loop) ────────────────
sysGrav: {[a] @[a;`vy;:;(a`vy)+gGrav*gDt]}
sysMove: {[a] a:@[a;`px;:;(a`px)+gDt*a`vx]; @[a;`py;:;(a`py)+gDt*a`vy]}
sysAge:  {[a] @[a;`life;:;(a`life)-gDt]}

/ ── emitter: enqueue new particles (deferred spawn) ─────────────────────────────
/ a fan of velocities spread by index, all from the bottom-centre
emitOne: {[w;h;k]
  ang: (-1.2)+0.3*k
  ecsCmdSpawn[`id`px`py`vx`vy`life!(ecsId[]; w*0.5; h*0.8; 240.*sin ang; (-300.); 3.0)]}
emit: {[w;h;n] emitOne[w;h]'!n; 0}

/ ── reaper: enqueue kills for dead (life≤0) or off-screen particles ─────────────
reapOne: {[a;i] ecsCmdKill[(a`id)i]}
reap: {[a;h] dead: &(~((a`life)>0.))|((a`py)>h); reapOne[a]'dead; 0}

/ ── render: one batched vertex buffer of particle quads ─────────────────────────
psz:: 6.
/ All particle quads in ONE vectorized pass — no per-entity loop. Build the 24
/ interleaved vertex columns (6 verts × x,y,u,v) over the whole px/py columns, flip
/ to per-particle rows, raze to a flat buffer. This is the library's whole thesis:
/ mesh assembly is a column op, not a `'!n each.
buildParts: {[a] $[ecsCount a; {[a] px:a`px; py:a`py; n:#px; x0:px-psz; y0:py-psz; x1:px+psz; y1:py+psz; z:n#0.; o:n#1.; ,/+(x0;y0;z;z; x1;y0;o;z; x1;y1;o;o; x0;y0;z;z; x1;y1;o;o; x0;y1;z;o)}a; !0]}

/ ── change-detection caches ─────────────────────────────────────────────────────
gPV:: !0; gPVe:: -1; gBuilds:: 0; gSkips:: 0
rebuildPV: {[e] gPV:: buildParts Particles; gPVe:: e; gBuilds:: gBuilds+1; 0}
syncPV: {[] e: epoch(Particles`px); $[e=gPVe; gSkips:: gSkips+1; rebuildPV[e]]; 0}

/ static background: source never changes → its epoch is stable → built once
gBG:: !0; gBGe:: -1; gBGsrc:: 1. 1. 1.; gBGskips:: 0
rebuildBG: {[w;h;e] gBG:: fullQuad[w;h]; gBGe:: e; 0}
syncBG: {[w;h] e: epoch gBGsrc; $[e=gBGe; gBGskips:: gBGskips+1; rebuildBG[w;h;e]]; 0}

/ ── helpers reused from the drawing demo ────────────────────────────────────────
rect: {[x;y;w;h] ,/(x,y,0.,0.; (x+w),y,1.,0.; (x+w),(y+h),1.,1.; x,y,0.,0.; (x+w),(y+h),1.,1.; x,(y+h),0.,1.)}
fullQuad: {[w;h] rect[0.;0.;w;h]}

/ ── diagnostics ─────────────────────────────────────────────────────────────────
gFrame:: 0
diag: {[] `0 0: $`frame`live`partBuilds`partSkips`bgSkips!(gFrame; ecsCount Particles; gBuilds; gSkips; gBGskips)}

/ ── frame loop ──────────────────────────────────────────────────────────────────
RunWindow[{[props]
  w: props`width; h: props`height
  gFrame:: gFrame+1
  / 1. systems (whole-column updates)
  Particles:: Tick[Particles; (sysGrav;sysMove;sysAge)]
  / 2. structural change via command buffer, then flush at the boundary
  reap[Particles; h]
  $[(gFrame mod 3)=0; emit[w;h;7]; 0]
  Particles:: ecsFlush[Particles]
  / 3. change detection — rebuild a layer only when its source dirtied
  syncBG[w;h]
  syncPV[]
  / 4. render — one batched FillFrame per layer
  FillFrame[gBG; gpuSolid[0.05;0.07;0.12;1.]]
  $[ecsCount Particles; FillFrame[gPV; gpuSolid[1.0;0.7;0.2;1.]]; 0]
  / 5. periodic diagnostics (prove deferred change + change detection)
  $[(gFrame mod 30)=0; diag[]; 0]
  0
}; 0]

/ demo/timer.k — 7GUIs #4 (Timer): elapsed gauge, live clock, adjustable duration, reset.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/timer.k
/ Snapshot:             ink -snap 0.6 demo/timer.k
/
/ The render loop IS the clock: `props`time` (seconds) drives everything — no threads. Elapsed =
/ now − t0, clamped to the duration; the gauge is elapsed/duration; the slider sets the duration
/ live (drag it below elapsed and the gauge is instantly full); Reset zeroes t0. Duration lives in
/ a ui slider buffer (ui.getv`dur); the only app state is `t0` and the per-frame `now`.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0
ui.setv[`dur; 15.]                       / initial duration (s)

\d world
  t0: 0.; now: 0.; el: 0.                 / reset time, current time, clamped elapsed
  / tick/reset WRITE el/now from INSIDE the namespace — a member only written from OUTSIDE
  / (world.el::…) isn't visible to functions reading it by bare name when file-loaded.
  tick:{[t;d] now::t; el:: (t-t0)&d}       / advance clock, clamp elapsed to duration
  reset:{[] t0::now}
  act:{[a] $[a~`reset; reset[]; 0]}
  fmt:{[x] ($0.1*_0.5+10.*x)," s"}         / 1-decimal seconds
  view:{[] d:ui.getv[`dur]; ui.bg[0.96 0.96 0.98 1.; ui.pad[40.; ui.col[22.; (
    ui.label["Timer"]
    ui.row[16.; ( ui.sized[110.;28.; ui.label["Elapsed:"]] ; ui.progress[$[d>0.;el%d;1.]; 300.; 22.] )]
    ui.sized[300.;26.; ui.label fmt el]
    ui.row[16.; ( ui.sized[110.;28.; ui.label["Duration:"]] ; ui.slider[`dur; 300.; 0.; 60.] )]
    ui.sized[300.;26.; ui.label fmt d]
    ui.button["Reset"; `reset]
    ui.spacer[] )]]}
\d

run:{[props]
  world.tick[props`time; ui.getv[`dur]]              / advance the clock (internal setter)
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 520. 420.]

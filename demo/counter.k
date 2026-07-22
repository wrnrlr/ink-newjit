/ demo/counter.k — 7GUIs #1 (Counter) on the tables-as-ECS UI + flexbox ui.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/counter.k
/ Headless snapshot:    ink -snap 0.4 demo/counter.k   (writes counter-snap*.png)
/
/ TWO independent counters from ONE reusable `counter` component. State lives under a `world`
/ namespace (world.count); the view is a pure model→layout-tree function; ui.run resolves
/ it against the real framebuffer viewport (× dpr), so it fills the window at any DPI — no
/ hard-coded pixel sizes.

2: "lib/ui.k"

/ ── model: all app/UI state under `world` ──
world.count: `c1`c2!0 0
world.act:{[a] $[a~`nop; 0; world.count[a]:: 1 + world.count a]}   / controller

/ ── a reusable component: label + button bound to counter `key` ──
counter:{[key] ui.row[16.; (
  ui.sized[150.; 36.; ui.label["Count: ",$world.count key]]
  ui.button["count up"; key] )]}

/ ── view: model → layout tree (pure) ──
world.view:{[] ui.bg[0.97 0.97 0.98 1.; ui.pad[40.; ui.col[18.; (
  ui.label["two counters, one component"]
  counter[`c1]
  counter[`c2]
  ui.spacer[] )]]]}

/ ── frame: input (hit-test events) → update model → repaint fresh view ──
run:{[props]
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

ui.setFont (font.read "font/FiraCode-Regular.ttf") 0
window.run[run; 640. 360.]

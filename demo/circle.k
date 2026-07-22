/ demo/circle.k — 7GUIs #6 (Circle Drawer): custom canvas, selection, undo/redo, radius editor.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/circle.k
/ Snapshot:             ink -snap 0.4 demo/circle.k
/ (The old SPIR-V circle-SDF shader example moved to demo/sdf.k.)
/
/ Left-click empty space to drop a circle; click a circle to edit its radius (a slider bar appears);
/ the circle under the cursor is highlighted. UNDO/REDO walk a history of column SNAPSHOTS — under
/ copy-on-write, snapshotting the (cx;cy;cr) columns is nearly free, which is why undo is a few lines.
/ The canvas is a `ui.canvas` widget whose paint is delegated to world.paint via ui.onCanvas.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0
ui.setv[`rad; 30.]

\d world
  cx:0#0.; cy:0#0.; cr:0#0.                 / circle columns (x;y;radius), framebuffer px
  sel: -1; editing: -1                       / hovered circle / circle being edited (-1 = none)
  hist: ,(0#0.;0#0.;0#0.)                     / undo history: snapshots of the 3 columns
  hpos: 0                                     / current position in the history

  / ── history: undo/redo = restore a column snapshot (cheap under COW) ──────────
  restore:{[s] cx::s 0; cy::s 1; cr::s 2}
  commit:{[] hist:: (hpos+1)#hist; hist:: hist,,(cx;cy;cr); hpos:: hpos+1}
  doUndo:{[] hpos::hpos-1; restore hist hpos}
  doRedo:{[] hpos::hpos+1; restore hist hpos}
  undo:{[] $[hpos>0; doUndo[]; 0]}
  redo:{[] $[hpos<(#hist)-1; doRedo[]; 0]}

  / ── selection: nearest circle whose radius contains (x,y), else -1 ────────────
  pickAt:{[x;y] d2:((x-cx)*(x-cx))+(y-cy)*(y-cy); i:d2?&/d2; $[(d2 i)<(cr i)*cr i; i; -1]}
  pick:{[x;y] $[0=#cx; -1; pickAt[x;y]]}
  hover:{[mx;my] sel:: $[editing<0; pick[mx;my]; editing]}

  / ── interaction: click empty → add; click a circle → edit its radius ──────────
  addCircle:{[x;y] cx::cx,x; cy::cy,y; cr::cr,25.; commit[]}
  startEdit:{[i] editing::i; ui.setv[`rad; cr i]}
  click:{[x;y] i:pick[x;y]; $[i<0; addCircle[x;y]; startEdit i]}
  setR:{[] cr[editing]::ui.getv[`rad]}
  editTick:{[] $[editing<0; 0; setR[]]}       / live-drag the edited circle's radius from the slider
  doneEdit:{[] commit[]; editing:: -1}
  act:{[a] $[a~`canvas; click[ui.cvx; ui.cvy]; a~`undo; undo[]; a~`redo; redo[]; a~`done; doneEdit[]; 0]}

  / ── drawing (canvas paint callback: rect in framebuffer px) ───────────────────
  drawOne:{[i]
    cnv.circle[cx i; cy i; cr i]
    $[(i=sel)|i=editing; cnv.fill cnv.rgba[0.80;0.86;0.98;1.]; 0]
    cnv.circle[cx i; cy i; cr i]
    cnv.stroke[cnv.rgba[0.15;0.15;0.20;1.]; 2.]}
  paint:{[x;y;w;h] cnv.save[]; cnv.clip[x;y;w;h]; {drawOne x}'!#cx; cnv.restore[]}

  editBar:{[] ui.bg[0.90 0.92 0.96 1.; ui.pad[10.; ui.row[12.; (
    ui.sized[70.;30.; ui.label["Radius"]]
    ui.slider[`rad; 240.; 5.; 90.]
    ui.button["Done"; `done] )]]}
  / kids built as a local: a newline before `,` INSIDE ui.col[…] would make it a separate arg.
  bar:{[] $[editing<0; (); ,editBar[]]}         / the radius bar, only while editing (0 or 1 node)
  view:{[]
    top: ui.row[10.; ( ui.button["Undo"; `undo] ; ui.button["Redo"; `redo] )]
    kids: (top ; ui.canvas[`cv]) , bar[]
    ui.bg[0.96 0.96 0.98 1.; ui.pad[16.; ui.col[10.; kids]]]}
\d

ui.onCanvas {[x;y;w;h] world.paint[x;y;w;h]}

run:{[props]
  world.hover[props`mx; props`my]
  world.editTick[]
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 640. 520.]

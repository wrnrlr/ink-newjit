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

world.cx:0#0.; world.cy:0#0.; world.cr:0#0.                 / circle columns (x;y;radius), framebuffer px
world.sel: -1; world.editing: -1                       / hovered circle / circle being edited (-1 = none)
world.hist: ,(0#0.;0#0.;0#0.)                     / undo history: snapshots of the 3 columns
world.hpos: 0                                     / current position in the history

  / ── history: undo/redo = restore a column snapshot (cheap under COW) ──────────
world.restore:{[s] world.cx::s 0; world.cy::s 1; world.cr::s 2}
world.commit:{[] world.hist:: (world.hpos+1)#world.hist; world.hist:: world.hist,,(world.cx;world.cy;world.cr); world.hpos:: world.hpos+1}
world.doUndo:{[] world.hpos::world.hpos-1; world.restore world.hist world.hpos}
world.doRedo:{[] world.hpos::world.hpos+1; world.restore world.hist world.hpos}
world.undo:{[] $[world.hpos>0; world.doUndo[]; 0]}
world.redo:{[] $[world.hpos<(#world.hist)-1; world.doRedo[]; 0]}

  / ── selection: nearest circle whose radius contains (x,y), else -1 ────────────
world.pickAt:{[x;y] d2:((x-world.cx)*(x-world.cx))+(y-world.cy)*(y-world.cy); i:d2?&/d2; $[(d2 i)<(world.cr i)*world.cr i; i; -1]}
world.pick:{[x;y] $[0=#world.cx; -1; world.pickAt[x;y]]}
world.hover:{[mx;my] world.sel:: $[world.editing<0; world.pick[mx;my]; world.editing]}

  / ── interaction: click empty → add; click a circle → edit its radius ──────────
world.addCircle:{[x;y] world.cx::world.cx,x; world.cy::world.cy,y; world.cr::world.cr,25.; world.commit[]}
world.startEdit:{[i] world.editing::i; ui.setv[`rad; world.cr i]}
world.click:{[x;y] i:world.pick[x;y]; $[i<0; world.addCircle[x;y]; world.startEdit i]}
world.setR:{[] world.cr[world.editing]::ui.getv[`rad]}
world.editTick:{[] $[world.editing<0; 0; world.setR[]]}       / live-drag the edited circle's radius from the slider
world.doneEdit:{[] world.commit[]; world.editing:: -1}
world.act:{[a] $[a~`canvas; world.click[ui.cvx; ui.cvy]; a~`undo; world.undo[]; a~`redo; world.redo[]; a~`done; world.doneEdit[]; 0]}

  / ── drawing (canvas paint callback: rect in framebuffer px) ───────────────────
world.drawOne:{[i]
    cnv.circle[world.cx i; world.cy i; world.cr i]
    $[(i=world.sel)|i=world.editing; cnv.fill cnv.rgba[0.80;0.86;0.98;1.]; 0]
    cnv.circle[world.cx i; world.cy i; world.cr i]
    cnv.stroke[cnv.rgba[0.15;0.15;0.20;1.]; 2.]}
world.paint:{[x;y;w;h] cnv.save[]; cnv.clip[x;y;w;h]; {world.drawOne x}'!#world.cx; cnv.restore[]}

world.editBar:{[] ui.bg[0.90 0.92 0.96 1.; ui.pad[10.; ui.row[12.; (
    ui.sized[70.;30.; ui.label["Radius"]]
    ui.slider[`rad; 240.; 5.; 90.]
    ui.button["Done"; `done] )]]}
  / kids built as a local: a newline before `,` INSIDE ui.col[…] would make it a separate arg.
bar:{[] $[world.editing<0; (); ,world.editBar[]]}         / the radius bar, only while editing (0 or 1 node)
view:{[]
    top: ui.row[10.; ( ui.button["Undo"; `undo] ; ui.button["Redo"; `redo] )]
    kids: (top ; ui.canvas[`cv]) , bar[]
    ui.bg[0.96 0.96 0.98 1.; ui.pad[16.; ui.col[10.; kids]]]}

ui.onCanvas {[x;y;w;h] world.paint[x;y;w;h]}

run:{[props]
  world.hover[props`mx; props`my]
  world.editTick[]
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 640. 520.]

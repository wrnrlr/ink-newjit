/ demo/crud.k — 7GUIs #5 (CRUD): filtered list + create/read/update/delete over a table model.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/crud.k
/ Snapshot:             ink -snap 0.4 demo/crud.k
/
/ The model is a TABLE (parallel `nms`/`srs` columns) and every operation is an array op: filter
/ = prefix-match mask over the surname column; create = append; update = amend-at-index; delete =
/ mask-out. The list shows the FILTERED rows; the selection is an index into that filtered view.
/ Members are mutated only by functions INSIDE \d world (external `world.x::` isn't seen by inside
/ readers when file-loaded — see .plan/triage.md).

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0
ui.setv[`ppl; -1.]                        / selected index into the filtered list (-1 = none)

\d world
  nms: ("Hans"; "Max"; "Roman")            / name column
  srs: ("Emil"; "Mustermann"; "Tisch")     / surname column
  / filtered model indices: surnames starting with the filter prefix (empty prefix matches all).
  / compare CODEPOINTS not chars — a single-char string is an atom, and atom~1-vector is false.
  pfx:{[p;x] $[0=#p; 1; (#p)>#x; 0; &/(`i$p)=(#p)#`i$x]}
  filt:{[] p:ui.get`flt; &pfx[p;]'srs}
  items:{[] {[i] (srs i),", ",nms i}'filt[]}          / "Surname, Name" per filtered row
  selRow:{[] f:filt[]; s:`i$ui.getv`ppl; $[(s<0)|~s<#f; -1; f s]}   / model index of the selection

  create:{[] nms::nms,,ui.get`nm; srs::srs,,ui.get`sur}
  doUpd:{[m] nms[m]::ui.get`nm; srs[m]::ui.get`sur}
  doDel:{[m] k:&~m=!#nms; nms::nms@k; srs::srs@k; ui.setv[`ppl; -1.]}
  update:{[] m:selRow[]; $[m<0; 0; doUpd m]}
  del:{[] m:selRow[]; $[m<0; 0; doDel m]}
  act:{[a] $[a~`create; create[]; a~`update; update[]; a~`delete; del[]; 0]}

  fld:{[cap;key;ph] ui.row[10.; ( ui.sized[86.;34.; ui.label cap] ; ui.input[key; 220.; ph] )]}
  view:{[] ui.bg[0.96 0.96 0.98 1.; ui.pad[26.; ui.col[14.; (
    ui.label["CRUD"]
    fld["Filter:"; `flt; "surname prefix"]
    ui.list[`ppl; items[]; 316.; 150.]
    fld["Name:"; `nm; "name"]
    fld["Surname:"; `sur; "surname"]
    ui.row[10.; ( ui.button["Create"; `create] ; ui.button["Update"; `update] ; ui.button["Delete"; `delete] )]
    ui.spacer[] )]]}
\d

run:{[props]
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 480. 480.]

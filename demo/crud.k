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

world.nms: ("Hans"; "Max"; "Roman")            / name column
world.srs: ("Emil"; "Mustermann"; "Tisch")     / surname column
  / filtered model indices: surnames starting with the filter prefix (empty prefix matches all).
  / compare CODEPOINTS not chars — a single-char string is an atom, and atom~1-vector is false.
world.pfx:{[p;x] $[0=#p; 1; (#p)>#x; 0; &/(`i$p)=(#p)#`i$x]}
world.filt:{[] p:ui.get`flt; &world.pfx[p;]'world.srs}
world.items:{[] {[i] (world.srs i),", ",world.nms i}'world.filt[]}          / "Surname, Name" per filtered row
world.selRow:{[] f:world.filt[]; s:`i$ui.getv`ppl; $[(s<0)|~s<#f; -1; f s]}   / model index of the selection

world.create:{[] world.nms::world.nms,,ui.get`nm; world.srs::world.srs,,ui.get`sur}
world.doUpd:{[m] world.nms[m]::ui.get`nm; world.srs[m]::ui.get`sur}
world.doDel:{[m] k:&~m=!#world.nms; world.nms::world.nms@k; world.srs::world.srs@k; ui.setv[`ppl; -1.]}
world.update:{[] m:world.selRow[]; $[m<0; 0; world.doUpd m]}
world.del:{[] m:world.selRow[]; $[m<0; 0; world.doDel m]}
world.act:{[a] $[a~`create; world.create[]; a~`update; world.update[]; a~`delete; world.del[]; 0]}

world.fld:{[cap;key;ph] ui.row[10.; ( ui.sized[86.;34.; ui.label cap] ; ui.input[key; 220.; ph] )]}
world.view:{[] ui.bg[0.96 0.96 0.98 1.; ui.pad[26.; ui.col[14.; (
    ui.label["CRUD"]
    world.fld["Filter:"; `flt; "surname prefix"]
    ui.list[`ppl; world.items[]; 316.; 150.]
    world.fld["Name:"; `nm; "name"]
    world.fld["Surname:"; `sur; "surname"]
    ui.row[10.; ( ui.button["Create"; `create] ; ui.button["Update"; `update] ; ui.button["Delete"; `delete] )]
    ui.spacer[] )]]]}

run:{[props]
  W: ui.run[world.view[]; props]
  {world.act x}' ui.frame[W; props]
  ui.draw[ui.run[world.view[]; props]; props`width; props`height]}

window.run[run; 480. 480.]

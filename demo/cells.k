/ demo/cells.k — 7GUIs #7 (Cells): a mini spreadsheet with formulas + dependency recompute.
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/cells.k
/ Snapshot:             ink -snap 0.4 demo/cells.k
/
/ Click a cell to select it; its raw text appears in the formula bar. Type a number, or a formula
/ like  =A0+B1*2  (cell refs + - * /, evaluated left-to-right). Changing any cell RECOMPUTES the
/ whole sheet to a fixpoint, so dependent cells update automatically. Model = two dicts (RAW text,
/ VAL numbers); formula eval is a tiny tokenizer (no built-in string-eval exists — `.` only parses
/ literals, `exec` is a shell verb). The array-language payoff: recompute is a few whole-sheet passes.

2: "lib/ui.k"
2: "lib/fmt.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0

sheet.ALPHA:"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
sheet.COLS:"ABCDE"; sheet.NR:6                             / grid: columns A–E, rows 0–5
sheet.CW:78.; sheet.CH:26.
sheet.RAW:(,`z)!,""                                  / cell (sym) → raw text
sheet.VAL:(,`z)!,0.                                  / cell (sym) → computed number
sheet.selCell:`none

  / ── formula evaluation (left-to-right; refs look up VAL, numbers via `.`) ──────
sheet.look:{[nm] $[nm in !sheet.VAL; sheet.VAL nm; 0.]}
sheet.operand:{[t] $[(*t) in sheet.ALPHA; sheet.look `s$t; . (0#" "),t]}   / cell ref or number literal
sheet.applyOp:{[a;o;v] $[o="+";a+v; o="-";a-v; o="*";a*v; (o="/")|o="%";a%v; a]}
sheet.evalExpr:{[s]
    op: s in "+-*/%"
    pcs: (0,&op) _ s                             / operand, then op+operand, op+operand, …
    opnds: (,pcs 0), {1_x}'1_pcs                 / enlist first (else `,` flattens the string)
    oprs: {*x}'1_pcs
    vs: sheet.operand'opnds
    {sheet.applyOp[x; y 0; y 1]}/[vs 0; +(oprs;1_vs)]}
sheet.isnum:{[s] v:(0#0),`i$s; $[0=#v;0;sheet.nv v]}
sheet.nv:{[v] neg:45=*v; t:$[neg;1_v;v]; $[0=#t;0;sheet.ad t]}
sheet.ad:{[t] isd:(~t<48)&(~t>57); isdot:t=46; (&/isd|isdot)&(~1<+/isdot)&0<+/isd}
sheet.evalCell:{[r] $[0=#r; 0.; "="~*r; sheet.evalExpr 1_r; sheet.isnum r; . (0#" "),r; 0.]}

  / ── recompute: iterate the whole sheet to a fixpoint (acyclic ⇒ #cells passes suffice) ──
sheet.onePass:{[] {[c] sheet.VAL[c]::sheet.evalCell sheet.RAW c}'!sheet.RAW}
sheet.recompute:{[] p:{[i] sheet.onePass[]}; p'!1|#!sheet.RAW; 0}
sheet.setCell:{[c;s] sheet.RAW[c]::s; sheet.recompute[]}
sheet.getRaw:{[c] $[c in !sheet.RAW; sheet.RAW c; ""]}

  / ── selection + editing (formula bar buffer `fx`) ────────────────────────────
sheet.select:{[c] sheet.selCell::c; ui.set[`fx; sheet.getRaw c]; ui.setFocus[`fx]}
sheet.syncEdit:{[] $[sheet.selCell~`none; 0; sheet.syncCell[]]}
sheet.syncCell:{[] cur:ui.get`fx; $[cur~sheet.getRaw sheet.selCell; 0; sheet.setCell[sheet.selCell; cur]]}
sheet.act:{[a] $[a~`nop; 0; sheet.select a]}

  / ── view ──────────────────────────────────────────────────────────────────────
sheet.cid:{[ci;r] `s$(,sheet.COLS ci),$r}
sheet.fmtV:{[v] $[v=`i$v; $`i$v; fmt.dec[2;v]]}
sheet.disp:{[c] $[0=#sheet.getRaw c; ""; sheet.fmtV sheet.look c]}
sheet.mkCell:{[r;ci] c:sheet.cid[ci;r]; ui.cell[c; sheet.disp c; sheet.CW; sheet.CH; sheet.selCell~c]}
sheet.cellsRow:{[r] sheet.mkCell[r;]'!#sheet.COLS}
  / bracket the label arg: `ui.label $r` / `ui.label ,x` make `$`/`,` DYADIC (a noun precedes them).
sheet.rowHdr:{[r] ui.sized[30.;sheet.CH; ui.label[$r]]}
sheet.gridRow:{[r] ui.row[2.; (,sheet.rowHdr r), sheet.cellsRow r]}
sheet.colHdr:{[] ui.row[2.; (,ui.sized[30.;22.; ui.label[""]]), sheet.colLbl'!#sheet.COLS]}
sheet.colLbl:{[ci] ui.sized[sheet.CW;22.; ui.label[,sheet.COLS ci]]}
sheet.grid:{[] ui.col[2.; (,sheet.colHdr[]), sheet.gridRow'!sheet.NR]}
sheet.view:{[]
    fbar: ui.row[8.; ( ui.sized[70.;30.; ui.label[sheet.selName[]]] ; ui.input[`fx; 380.; "value or =A0+B1"] )]
    ui.bg[0.96 0.96 0.98 1.; ui.pad[18.; ui.col[12.; (fbar ; sheet.grid[]) ]]]}
sheet.selName:{[] $[sheet.selCell~`none; "cell:"; $sheet.selCell]}

/ seed a little sheet so it isn't blank
sheet.setCell[`A0;"5"]; sheet.setCell[`B0;"3"]
sheet.setCell[`A1;"=A0*2"]; sheet.setCell[`B1;"=A0+B0"]
sheet.setCell[`C0;"=A1+B1"]

run:{[props]
  sheet.syncEdit[]                     / commit any formula-bar edit → recompute
  W: ui.run[sheet.view[]; props]
  {sheet.act x}' ui.frame[W; props]
  ui.draw[ui.run[sheet.view[]; props]; props`width; props`height]}

window.run[run; 560. 320.]

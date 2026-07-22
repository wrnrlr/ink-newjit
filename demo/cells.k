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

\d sheet
  ALPHA:"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  COLS:"ABCDE"; NR:6                             / grid: columns A–E, rows 0–5
  CW:78.; CH:26.
  RAW:(,`z)!,""                                  / cell (sym) → raw text
  VAL:(,`z)!,0.                                  / cell (sym) → computed number
  selCell:`none

  / ── formula evaluation (left-to-right; refs look up VAL, numbers via `.`) ──────
  look:{[nm] $[nm in !VAL; VAL nm; 0.]}
  operand:{[t] $[(*t) in ALPHA; look `s$t; . (0#" "),t]}   / cell ref or number literal
  applyOp:{[a;o;v] $[o="+";a+v; o="-";a-v; o="*";a*v; (o="/")|o="%";a%v; a]}
  evalExpr:{[s]
    op: s in "+-*/%"
    pcs: (0,&op) _ s                             / operand, then op+operand, op+operand, …
    opnds: (,pcs 0), {1_x}'1_pcs                 / enlist first (else `,` flattens the string)
    oprs: {*x}'1_pcs
    vs: operand'opnds
    {applyOp[x; y 0; y 1]}/[vs 0; +(oprs;1_vs)]}
  isnum:{[s] v:(0#0),`i$s; $[0=#v;0;nv v]}
  nv:{[v] neg:45=*v; t:$[neg;1_v;v]; $[0=#t;0;ad t]}
  ad:{[t] isd:(~t<48)&(~t>57); isdot:t=46; (&/isd|isdot)&(~1<+/isdot)&0<+/isd}
  evalCell:{[r] $[0=#r; 0.; "="~*r; evalExpr 1_r; isnum r; . (0#" "),r; 0.]}

  / ── recompute: iterate the whole sheet to a fixpoint (acyclic ⇒ #cells passes suffice) ──
  onePass:{[] {[c] VAL[c]::evalCell RAW c}'!RAW}
  recompute:{[] p:{[i] onePass[]}; p'!1|#!RAW; 0}
  setCell:{[c;s] RAW[c]::s; recompute[]}
  getRaw:{[c] $[c in !RAW; RAW c; ""]}

  / ── selection + editing (formula bar buffer `fx`) ────────────────────────────
  select:{[c] selCell::c; ui.set[`fx; getRaw c]; ui.setFocus[`fx]}
  syncEdit:{[] $[selCell~`none; 0; syncCell[]]}
  syncCell:{[] cur:ui.get`fx; $[cur~getRaw selCell; 0; setCell[selCell; cur]]}
  act:{[a] $[a~`nop; 0; select a]}

  / ── view ──────────────────────────────────────────────────────────────────────
  cid:{[ci;r] `s$(,COLS ci),$r}
  fmtV:{[v] $[v=`i$v; $`i$v; fmt.dec[2;v]]}
  disp:{[c] $[0=#getRaw c; ""; fmtV look c]}
  mkCell:{[r;ci] c:cid[ci;r]; ui.cell[c; disp c; CW; CH; selCell~c]}
  cellsRow:{[r] mkCell[r;]'!#COLS}
  / bracket the label arg: `ui.label $r` / `ui.label ,x` make `$`/`,` DYADIC (a noun precedes them).
  rowHdr:{[r] ui.sized[30.;CH; ui.label[$r]]}
  gridRow:{[r] ui.row[2.; (,rowHdr r), cellsRow r]}
  colHdr:{[] ui.row[2.; (,ui.sized[30.;22.; ui.label[""]]), colLbl'!#COLS]}
  colLbl:{[ci] ui.sized[CW;22.; ui.label[,COLS ci]]}
  grid:{[] ui.col[2.; (,colHdr[]), gridRow'!NR]}
  view:{[]
    fbar: ui.row[8.; ( ui.sized[70.;30.; ui.label[selName[]]] ; ui.input[`fx; 380.; "value or =A0+B1"] )]
    ui.bg[0.96 0.96 0.98 1.; ui.pad[18.; ui.col[12.; (fbar ; grid[]) ]]]}
  selName:{[] $[selCell~`none; "cell:"; $selCell]}
\d

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

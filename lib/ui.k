/ lib/ui.k — the primitive UI layer: a widget is a ROW, the UI is a column table (ECS
/ archetype), a frame is a few vectorised passes. Layout lives in lib/layout.k on top of this.
/
/ Build first:  zig build gpu
/ Load with:    2: "lib/ui.k"   (or 2: "lib/layout.k", which pulls this in)
/
/ A component returns ROW-TUPLES; `ui.build` transposes ONCE into a column dict W (SoA).
/ Columns:  id x y w h bg txt fg sz act  (bg/fg = F4 or (); txt = string; act = symbol).
/ act = `nop inert, `focus a text input; any other symbol is an app action fired on click.
/ Interaction state (text buffers, focus, caret) is framework-owned, keyed by widget id — the
/ imgui "storage" trick — so it survives the immediate-mode view rebuild.

2: "lib/canvas.k"

\d ui mkw build hit paint measure fnt setFont frame get set isFocus focus caret

  COLS: `id`x`y`w`h`bg`txt`fg`sz`act
  FONT: ()                                   / app sets this via ui.setFont
  setFont:{[f] FONT::f}
  fnt:{[] FONT}
  CW: 0.6                                     / monospace advance / em (FiraCode)

  / One widget row as a 10-tuple (rect grouped to stay under ink's 8-param lambda cap).
  mkw:{[id;rect;bg;txt;fg;sz;act] (id;rect 0;rect 1;rect 2;rect 3;bg;txt;fg;sz;act)}
  build:{[rows] COLS! +rows}
  measure:{[sz;s] (#s)*sz*CW}                 / text width px (monospace ⇒ exact)

  / ── interaction state (keyed by widget id) ───────────────────────────────────
  buf:  (,`none)!,""                          / id → text buffer (string)
  focus: `none                                / id of the focused input (`none = none)
  caret: 0                                    / caret column within the focused buffer
  get:{[k] $[k in !buf; buf k; ""]}
  set:{[k;s] buf[k]:: s}
  isFocus:{[k] focus~k}

  / ── hit-test (vectorised): all widgets containing (px,py); topmost = last row ──
  hit:{[W;px;py]
    x:W`x; y:W`y; w:W`w; h:W`h
    i:&((~px<x)&(px<x+w))&(~py<y)&(py<y+h)
    $[#i; *|i; -1]}

  / ── clicks: focus inputs, defocus on a miss/button, return app actions ────────
  caretCol:{[px;x0;sz;s] 0|(_0.5+(px-x0)%sz*CW)&#s}
  / clamp the caret against the real BUFFER (not the row's shown text, which may be a placeholder).
  doFocus:{[W;i;px] k:(W`id)@i; focus::k; caret::caretCol[px; ((W`x)@i)+6.; (W`sz)@i; get k]; `nop}
  hitAct:{[W;i] focus::`none; (W`act)@i}
  onHit:{[W;i;px] $[((W`act)@i)~`focus; doFocus[W;i;px]; hitAct[W;i]]}
  defocus:{[] focus::`none; `nop}
  dispatchClick:{[W;px;py] i:hit[W;px;py]; $[i<0; defocus[]; onHit[W;i;px]]}
  dispatchPt:{[W;p] dispatchClick[W; p 0; p 1]}
  mouseActs:{[W;E]
    i:&((`mouse=E`kind)&(1=E`down))&(0=E`code)
    dispatchPt[W;]'+((E`x)@i;(E`y)@i)}

  / ── editing the focused buffer (mechanics lifted from demo/edit.k) ────────────
  insChDo:{[cp] k:focus; s:get k; c:caret; set[k; (c#s),(`c$cp),(c_s)]; caret::c+1}
  insCh:{[cp] $[focus~`none; 0; insChDo cp]}
  backDo:{[] k:focus; s:get k; c:caret; set[k; ((c-1)#s),(c_s)]; caret::c-1}
  delDo:{[] k:focus; s:get k; c:caret; set[k; (c#s),((c+1)_s)]}
  back:{[] $[caret>0; backDo[]; 0]}
  del:{[] $[caret<#get focus; delDo[]; 0]}
  left:{[] $[caret>0; caret::caret-1; 0]}
  right:{[] $[caret<#get focus; caret::caret+1; 0]}
  home:{[] caret::0}
  end:{[] caret:: #get focus}
  / GLFW keycodes (see edit.k): 259 back, 261 del, 263/262 ←→, 268/269 home/end.
  editKey:{[k] $[k=259;back[]; k=261;del[]; k=263;left[]; k=262;right[]; k=268;home[]; k=269;end[]; 0]}
  editText:{[E] pf:{insCh x}; pf' 0+(E`code)@&`text=E`kind}       / 0+ copies out of C event mem
  editKeys:{[E] pf:{editKey x}; pf' 0+(E`code)@&(`key=E`kind)&1=E`down}
  keys:{[E] $[focus~`none; 0; keysDo E]}
  keysDo:{[E] editText E; editKeys E; 0}

  / One entry point per frame: handle clicks (focus + collect app actions) + keyboard.
  frame:{[W;E] a:mouseActs[W;E]; keys E; a}

  / ── paint: each row → canvas ops (canvas re-batches into ONE GPU scene buffer) ──
  fillRect:{[x;y;w;h;c] cnv.rect[x;y;w;h]; cnv.fill cnv.rgba[c 0;c 1;c 2;c 3]}
  drawTxt:{[x;y;sz;s;c] cnv.moveTo[x;y]; cnv.text[FONT; sz; s; cnv.rgba[c 0;c 1;c 2;c 3]]}
  drawCaret:{[tx;y;h;sz;col] cx:tx+col*sz*CW; cnv.rect[cx; y+0.15*h; 2.; 0.7*h]; cnv.fill cnv.rgba[0.2;0.5;0.95;1.]}
  paintRow:{[W;i]
    x:(W`x)i; y:(W`y)i; w:(W`w)i; h:(W`h)i; sz:(W`sz)i
    bg:(W`bg)i; txt:(W`txt)i; a:(W`act)i; id:(W`id)i
    inp:a~`focus
    $[~bg~(); fillRect[x;y;w;h;bg]; 0]
    / centre text in a button (has bg, not an input); left-align inputs and bare labels.
    center:(~bg~())&~inp
    tx:$[center; x+0.5*w-measure[sz;txt]; inp; x+6.; x+2.]
    by:y+$[h>0.; (0.5*h)+0.34*sz; sz]
    $[~txt~""; drawTxt[tx; by; sz; txt; (W`fg)i]; 0]
    $[inp&(id~focus); drawCaret[x+6.; y; h; sz; caret]; 0]}
  paint:{[W] pr:paintRow[W;]; pr'!#W`x}
\d

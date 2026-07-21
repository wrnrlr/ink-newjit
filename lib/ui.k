/ lib/ui.k — a tables-as-ECS immediate-mode UI toolkit (widgets + flexbox + input, one `ui`
/ namespace). Build GPU lib first: zig build gpu.  Load with: 2: "lib/ui.k".
/
/ MODEL. You describe the UI as a TREE of NODES (a node is a dict). `ui.run` solves the tree into
/ a flat WIDGET TABLE — a column dict W with columns  id x y w h bg txt fg sz act  (an ECS
/ archetype). A frame is three vectorised passes over W:
/   view   model            -> node tree     (pure; components are functions returning nodes)
/   frame  (W; props`events) -> app actions    (hit-test = ONE whole-array point-in-rect)
/   draw   W                 -> canvas ops      (per row → a fill/text; canvas re-batches)
/ Interaction state (text buffers, focus, caret, open menu) is framework-owned, keyed by widget
/ id (the imgui "storage" trick) so it survives the per-frame rebuild.
/
/ OVERLAYS. A popup (dropdown menu) is emitted as extra rows AFTER the main tree and rendered in a
/ SECOND cnv.render pass — the canvas draws all fills then all text per render, so a later render's
/ fills correctly occlude the base pass's text. Max 2 render passes per frame (see doc/design/ui.md).

2: "lib/canvas.k"

\d ui setFont fnt measure mkw build get set isFocus regOpts row col box label button input select spacer grow pad sized gap bg disabled invalid natSize solve run hit frame draw paint focus caret open

  / ── palette ──────────────────────────────────────────────────────────────────
  BLUE:0.22 0.45 0.95 1.; DARK:0.10 0.10 0.12 1.; WHITE:1. 1. 1. 1.; GREY:0.6 0.6 0.66 1.
  INBG:1. 1. 1. 1.; INFOC:0.90 0.94 1. 1.; MENUBG:1. 1. 1. 1.; MENUHI:0.90 0.94 1. 1.
  DISBG:0.88 0.88 0.90 1.; DISFG:0.62 0.62 0.66 1.; BADBG:1. 0.86 0.86 1.
  CW:0.6                                       / monospace advance / em (FiraCode)
  KEYS:`t`w`h`grow`dir`gap`pad`kids`id`bg`txt`fg`sz`act

  FONT:()
  setFont:{[f] FONT::f}
  fnt:{[] FONT}
  measure:{[sz;s] (#s)*sz*CW}                  / text width px (monospace ⇒ exact)

  / ── widget row (a 10-tuple; rect grouped to dodge ink's 8-param lambda cap) ────
  mkw:{[id;rect;bg;txt;fg;sz;act] (id;rect 0;rect 1;rect 2;rect 3;bg;txt;fg;sz;act)}
  build:{[rows] KEYSW! +rows}
  KEYSW:`id`x`y`w`h`bg`txt`fg`sz`act

  / ── interaction state (keyed by widget id) ───────────────────────────────────
  buf:(,`none)!,""                             / id → text buffer / selected value
  opts:(,`none)!,()                            / id → select option list
  focus:`none                                  / focused input id
  open:`none                                   / open dropdown id
  caret:0                                      / caret column in the focused buffer
  get:{[k] $[k in !buf; buf k; ""]}
  set:{[k;s] buf[k]:: s}
  isFocus:{[k] focus~k}
  regOpts:{[k;os] opts[k]:: os}

  / ── leaves (each returns a node dict) ────────────────────────────────────────
  box:{[color] KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();`box;color;"";DARK;0.;`nop)}
  label:{[s] KEYS!(`leaf;(measure[18.;s])+4.;26.;0.;`row;0.;0.;();`lbl;();s;DARK;18.;`nop)}
  button:{[s;act] KEYS!(`leaf;(measure[16.;s])+28.;36.;0.;`row;0.;0.;();`btn;BLUE;s;WHITE;16.;act)}
  spacer:{[] KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();`sp;();"";DARK;0.;`nop)}
  / A focusable text input `w` px wide, bound to buffer ui.get/ui.set[key]. act=`focus marks it.
  input:{[key;w;ph]
    s:get key; foc:isFocus key; empty:(s~"")&~foc
    KEYS!(`leaf;w;34.;0.;`row;0.;0.;();key;$[foc;INFOC;INBG];$[empty;ph;s];$[empty;GREY;DARK];16.;`focus)}
  / A dropdown bound to buffer ui.get/ui.set[key]. Click opens a menu (an overlay, ui.overlay);
  / picking writes the value. act=`open marks the box.
  select:{[key;w;options]
    regOpts[key;options]
    KEYS!(`leaf;w;34.;0.;`row;0.;0.;();key;$[open~key;INFOC;INBG];(get key)," v";DARK;16.;`open)}

  / ── containers ───────────────────────────────────────────────────────────────
  row:{[g;kids] KEYS!(`box;0.;0.;0.;`row;g;0.;kids;`row;();"";DARK;0.;`nop)}
  col:{[g;kids] KEYS!(`box;0.;0.;0.;`col;g;0.;kids;`col;();"";DARK;0.;`nop)}

  / ── combinators (amend one node field; chainable) ────────────────────────────
  grow:{[g;nd] @[nd;`grow;:;g]}
  pad:{[p;nd] @[nd;`pad;:;p]}
  sized:{[w;h;nd] @[@[nd;`w;:;w];`h;:;h]}
  gap:{[g;nd] @[nd;`gap;:;g]}
  bg:{[c;nd] @[nd;`bg;:;c]}
  disabled:{[nd] @[@[@[nd;`bg;:;DISBG];`fg;:;DISFG];`act;:;`nop]}
  invalid:{[nd] @[nd;`bg;:;BADBG]}

  / ── natSize: intrinsic content size, bottom-up ───────────────────────────────
  gwf:{x`w}; ghf:{x`h}; ggf:{x`grow}; gwf0:{x 0}; ghf0:{x 1}
  natSize:{[nd] $[(nd`t)~`leaf; (nd`w; nd`h); natBox nd]}
  natBox:{[nd] $[0=#nd`kids; (2.*nd`pad; 2.*nd`pad); natBox2 nd]}
  natBox2:{[nd]
    p:nd`pad; g:nd`gap; n:#nd`kids; szs:natSize'nd`kids
    ws:gwf0'szs; hs:ghf0'szs
    $[(nd`dir)~`row; ((+/ws)+(2.*p)+g*n-1; (|/hs)+2.*p); ((|/ws)+2.*p; (+/hs)+(2.*p)+g*n-1)]}

  / ── solve: tree → flat rows, scaled by dpr `s` to framebuffer px ──────────────
  exPre:{(+\x)-x}
  leafRows:{[nd;x;y;w;h;s]
    $[((nd`bg)~())&(nd`txt)~""; (); ,mkw[nd`id; s*x,y,w,h; nd`bg; nd`txt; nd`fg; s*nd`sz; nd`act]]}
  boxRows:{[nd;x;y;w;h;s]
    hdr:$[(nd`bg)~(); (); ,mkw[nd`id; s*x,y,w,h; nd`bg; ""; nd`fg; 0.; `nop]]
    hdr,$[0=#nd`kids; (); layoutKids[nd;x;y;w;h;s]]}
  csz:{[avail;k] $[k>0.; avail&k; avail]}
  mainf:{[rw;nats] $[rw; gwf0'nats; ghf0'nats]}
  crossf:{[rw;nats] $[rw; ghf0'nats; gwf0'nats]}
  layoutKids:{[nd;x;y;w;h;s]
    p:nd`pad; g:nd`gap; rw:(nd`dir)~`row; kids:nd`kids; n:#kids
    ix:x+p; iy:y+p; iw:w-2.*p; ih:h-2.*p
    mainAv:$[rw;iw;ih]; crossAv:$[rw;ih;iw]
    nats:natSize'kids
    base:mainf[rw;nats]; grows:ggf'kids
    slack:0.|(mainAv-(+/base))-g*0|n-1
    gs:+/grows
    sizes:base+$[gs>0.; slack*grows%gs; n#0.]
    starts:$[rw;ix;iy]+(exPre sizes)+g*!n
    crossSz:csz[crossAv;]'crossf[rw;nats]
    crossPos:$[rw;iy;ix]+0.5*crossAv-crossSz
    X:$[rw; starts; crossPos]; Y:$[rw; crossPos; starts]
    W:$[rw; sizes; crossSz];   H:$[rw; crossSz; sizes]
    ,/solve'[kids;X;Y;W;H;n#s]}
  solve:{[nd;x;y;w;h;s] $[(nd`t)~`leaf; leafRows[nd;x;y;w;h;s]; boxRows[nd;x;y;w;h;s]]}

  / ── overlay: the open dropdown's menu rows, stacked below its box (framebuffer px) ──
  mkOpt:{[x;yb;w;h;sz;key;j;s] mkw[key; x,(yb+h*j),w,h; MENUBG; s; DARK; sz; `pick]}
  menuRows:{[W]
    i:*&((open=W`id)&`open=W`act)
    x:(W`x)@i; h:(W`h)@i; os:opts open
    mkOpt[x; ((W`y)@i)+h; (W`w)@i; h; (W`sz)@i; open;]'[!#os; os]}
  overlay:{[W] $[open~`none; (); menuRows W]}

  / Solve `nd` over the viewport; append any open menu as trailing overlay rows.
  NOVL:0
  run:{[nd;props]
    s:props`dpr
    rows:solve[nd; 0.; 0.; (props`width)%s; (props`height)%s; s]
    W:build rows
    ov:overlay W
    NOVL::#ov
    build rows,ov}

  / ── hit-test (vectorised): topmost = last row ────────────────────────────────
  hit:{[W;px;py]
    x:W`x; y:W`y; w:W`w; h:W`h
    i:&((~px<x)&(px<x+w))&(~py<y)&(py<y+h)
    $[#i; *|i; -1]}

  / ── click dispatch: focus / open menu / pick option / defocus, return app acts ─
  caretCol:{[px;x0;sz;s] 0|(_0.5+(px-x0)%sz*CW)&#s}
  doFocus:{[W;i;px] k:(W`id)@i; focus::k; open::`none; caret::caretCol[px; ((W`x)@i)+6.; (W`sz)@i; get k]; `nop}
  toggleOpen:{[W;i] k:(W`id)@i; open:: $[open~k; `none; k]; focus::`none; `nop}
  pickOpt:{[W;i] set[(W`id)@i; (W`txt)@i]; open::`none; `nop}
  hitAct:{[W;i] focus::`none; open::`none; (W`act)@i}
  onHit:{[W;i;px]
    a:(W`act)@i
    $[a~`focus; doFocus[W;i;px]; a~`open; toggleOpen[W;i]; a~`pick; pickOpt[W;i]; hitAct[W;i]]}
  defocus:{[] focus::`none; open::`none; `nop}
  dispatchPt:{[W;p] i:hit[W;p 0;p 1]; $[i<0; defocus[]; onHit[W;i;p 0]]}
  mouseActs:{[W;E]
    i:&((`mouse=E`kind)&(1=E`down))&(0=E`code)
    dispatchPt[W;]'+((E`x)@i;(E`y)@i)}

  / ── editing the focused buffer (mechanics from demo/edit.k) ───────────────────
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
  editKey:{[k] $[k=259;back[]; k=261;del[]; k=263;left[]; k=262;right[]; k=268;home[]; k=269;end[]; 0]}
  editText:{[E] pf:{insCh x}; pf' 0+(E`code)@&`text=E`kind}
  editKeys:{[E] pf:{editKey x}; pf' 0+(E`code)@&(`key=E`kind)&1=E`down}
  keys:{[E] $[focus~`none; 0; keysDo E]}
  keysDo:{[E] editText E; editKeys E; 0}

  / One entry point per frame: clicks (focus/menu + app actions) + keyboard.
  frame:{[W;E] a:mouseActs[W;E]; keys E; a}

  / ── paint ────────────────────────────────────────────────────────────────────
  fillRect:{[x;y;w;h;c] cnv.rect[x;y;w;h]; cnv.fill cnv.rgba[c 0;c 1;c 2;c 3]}
  drawTxt:{[x;y;sz;s;c] cnv.moveTo[x;y]; cnv.text[FONT; sz; s; cnv.rgba[c 0;c 1;c 2;c 3]]}
  drawCaret:{[tx;y;h;sz;col] cx:tx+col*sz*CW; cnv.rect[cx; y+0.15*h; 2.; 0.7*h]; cnv.fill cnv.rgba[0.2;0.5;0.95;1.]}
  paintRow:{[W;i]
    x:(W`x)i; y:(W`y)i; w:(W`w)i; h:(W`h)i; sz:(W`sz)i
    bg:(W`bg)i; txt:(W`txt)i; a:(W`act)i; id:(W`id)i
    inp:a~`focus
    $[~bg~(); fillRect[x;y;w;h;bg]; 0]
    center:(~bg~())&(~inp)&~a~`open              / buttons centre; inputs/selects/labels left
    tx:$[center; x+0.5*w-measure[sz;txt]; x+6.]
    by:y+$[h>0.; (0.5*h)+0.34*sz; sz]
    $[~txt~""; drawTxt[tx; by; sz; txt; (W`fg)i]; 0]
    $[inp&(id~focus); drawCaret[x+6.; y; h; sz; caret]; 0]}
  paintRows:{[W;is] pr:paintRow[W;]; pr'is}
  paint:{[W] paintRows[W; !#W`x]}

  / draw: main UI as render 1; any overlay (NOVL trailing rows) as render 2, whose fills occlude
  / render 1's text (canvas draws fills-then-text per render, so a 2nd render composites on top).
  draw:{[W;w;h]
    n:#W`x; k:n-NOVL
    cnv.new[]; paintRows[W; !k]; cnv.render[w;h]
    $[NOVL>0; drawOv[W;k;n;w;h]; 0]}
  drawOv:{[W;k;n;w;h] cnv.new[]; paintRows[W; k+!n-k]; cnv.render[w;h]}
\d

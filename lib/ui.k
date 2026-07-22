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

\d ui setFont fnt measure mkw build get set getv setv isFocus setFocus regOpts row col box label button input select slider progress list canvas cell onCanvas cvx cvy spacer grow pad sized gap bg disabled invalid natSize solve run hit frame draw paint focus caret open

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
  val:(,`none)!,0.                             / id → numeric value (sliders)
  rng:(,`none)!,0. 1.                          / id → (min;max) for sliders
  focus:`none                                  / focused input id
  open:`none                                   / open dropdown id
  drag:`none                                   / slider being dragged (`none = none)
  dragx:0.; dragw:0.                           / dragged slider's track x / width
  caret:0                                      / caret column in the focused buffer
  get:{[k] $[k in !buf; buf k; ""]}
  set:{[k;s] buf[k]:: s}
  getv:{[k] $[k in !val; val k; 0.]}
  setv:{[k;x] val[k]:: x}
  isFocus:{[k] focus~k}
  setFocus:{[k] focus::k; caret:: #get k}       / focus an input from the app, caret at end
  regOpts:{[k;os] opts[k]:: os}
  regRng:{[k;r] rng[k]:: r}

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
  / A slider `w` px wide bound to ui.getv/ui.setv[key] over [mn;mx]. Click/drag the track to set.
  slider:{[key;w;mn;mx] regRng[key;mn,mx]; KEYS!(`leaf;w;28.;0.;`row;0.;0.;();key;();"";DARK;0.;`slide)}
  / A progress gauge (fraction 0..1), `w`×`h` — pure flexbox: a fill box grows to `frac` of a track.
  progress:{[frac;w;h] sized[w;h; bg[0.85 0.85 0.88 1.; row[0.; (
    grow[1e-4|frac; box[0.22 0.60 0.42 1.]] ; grow[1e-4|1.-frac; spacer[]] )]]]}
  / A selectable list box `w`×`h` showing `items` (strings). Click an item to select it; the
  / selected index is ui.getv/ui.setv[key]. act=`list; painted by drawList (highlight + text rows).
  list:{[key;items;w;h] regOpts[key;items]; KEYS!(`leaf;w;h;0.;`row;0.;0.;();key;INBG;"";DARK;16.;`list)}
  / A custom-draw canvas that fills its slot. `ui.onCanvas[fn]` sets a paint callback fn[x;y;w;h]
  / (rect in framebuffer px, called during paint); a click stores its position in ui.cvx/ui.cvy and
  / fires `canvas so the app can act on it.
  canvasCB:{[x;y;w;h] 0}
  onCanvas:{[fn] canvasCB::fn}
  cvx:0.; cvy:0.
  canvas:{[key] KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();key;INBG;"";DARK;0.;`canvas)}
  / A grid cell `w`×`h` showing `label`, highlighted when `hl`. Clicking fires `id (the app uses the
  / cell's own name as the action). For spreadsheets / tabular pickers.
  cell:{[id;label;w;h;hl] KEYS!(`leaf;w;h;0.;`row;0.;0.;();id;$[hl;SELBG;WHITE];label;DARK;15.;id)}

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
  / a leaf reports its own size; a container computes from children UNLESS `sized` set an explicit
  / w/h (>0), which then wins — otherwise a sized container (e.g. a progress track) collapses to 0.
  natSize:{[nd] $[(nd`t)~`leaf; (nd`w; nd`h); nbx nd]}
  nbx:{[nd] nb:natBox nd; ($[(nd`w)>0.; nd`w; nb 0]; $[(nd`h)>0.; nd`h; nb 1])}
  natBox:{[nd] $[0=#nd`kids; (2.*nd`pad; 2.*nd`pad); natBox2 nd]}
  natBox2:{[nd]
    p:nd`pad; g:nd`gap; n:#nd`kids; szs:natSize'nd`kids
    ws:gwf0'szs; hs:ghf0'szs
    $[(nd`dir)~`row; ((+/ws)+(2.*p)+g*n-1; (|/hs)+2.*p); ((|/ws)+2.*p; (+/hs)+(2.*p)+g*n-1)]}

  / ── solve: tree → flat rows, scaled by dpr `s` to framebuffer px ──────────────
  exPre:{(+\x)-x}
  / emit a row unless it's a pure spacer (no bg, no text, inert) — a slider has none of those but IS interactive.
  leafRows:{[nd;x;y;w;h;s]
    $[(((nd`bg)~())&(nd`txt)~"")&(nd`act)~`nop; (); ,mkw[nd`id; s*x,y,w,h; nd`bg; nd`txt; nd`fg; s*nd`sz; nd`act]]}
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
  / start dragging a slider: capture its track x/width, jump the value to the click x.
  slideTo:{[px] r:rng drag; f:0.|1.&(px-dragx)%dragw; setv[drag; (r 0)+f*(r 1)-r 0]}
  doSlide:{[W;i;px] drag::(W`id)@i; dragx::(W`x)@i; dragw::(W`w)@i; slideTo px; `nop}
  hitAct:{[W;i] focus::`none; open::`none; (W`act)@i}
  / click a list row → select the item under the cursor (index = row from the top, by geometry).
  ITEMK:1.7                                    / list item height / font size
  doList:{[W;i;py] k:(W`id)@i; n:#opts k; $[n=0; `nop; setList[W;i;py;k;n]]}
  setList:{[W;i;py;k;n] ih:ITEMK*(W`sz)@i; setv[k; 0.+0|(n-1)&_(py-(W`y)@i)%ih]; `nop}
  doCanvas:{[p] cvx::p 0; cvy::p 1; focus::`none; `canvas}
  onHit:{[W;i;p]
    a:(W`act)@i
    $[a~`focus; doFocus[W;i;p 0]; a~`open; toggleOpen[W;i]; a~`pick; pickOpt[W;i]; a~`slide; doSlide[W;i;p 0]; a~`list; doList[W;i;p 1]; a~`canvas; doCanvas[p]; hitAct[W;i]]}
  defocus:{[] focus::`none; open::`none; `nop}
  dispatchPt:{[W;p] i:hit[W;p 0;p 1]; $[i<0; defocus[]; onHit[W;i;p]]}
  mouseActs:{[W;E]
    i:&((`mouse=E`kind)&(1=E`down))&(0=E`code)
    dispatchPt[W;]'+((E`x)@i;(E`y)@i)}
  / a mouse RELEASE ends any drag; continuous drag reads props`mx each frame.
  releaseDrag:{[E] $[0<#&(`mouse=E`kind)&0=E`down; drag::`none; 0]}
  dragUpdate:{[props] $[drag~`none; 0; slideTo props`mx]}

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

  / One entry point per frame: clicks (focus/menu/slider + app actions), drag, keyboard.
  frame:{[W;props] E:props`events; a:mouseActs[W;E]; releaseDrag E; dragUpdate props; keys E; a}

  / ── paint ────────────────────────────────────────────────────────────────────
  fillRect:{[x;y;w;h;c] cnv.rect[x;y;w;h]; cnv.fill cnv.rgba[c 0;c 1;c 2;c 3]}
  drawTxt:{[x;y;sz;s;c] cnv.moveTo[x;y]; cnv.text[FONT; sz; s; cnv.rgba[c 0;c 1;c 2;c 3]]}
  drawCaret:{[tx;y;h;sz;col] cx:tx+col*sz*CW; cnv.rect[cx; y+0.15*h; 2.; 0.7*h]; cnv.fill cnv.rgba[0.2;0.5;0.95;1.]}
  / a list box: one text row per item; the selected row (ui.getv[key]) gets a highlight behind it.
  SELBG:0.80 0.89 1. 1.
  drawItem:{[x;y;w;ih;sz;sel;j;s]
    $[j=sel; fillRect[x; y+ih*j; w; ih; SELBG]; 0]
    drawTxt[x+8.; (y+ih*j)+0.66*ih; sz; s; 0.1 0.1 0.12 1.]}
  drawList:{[key;x;y;w;sz]
    items:opts key; ih:ITEMK*sz; sel:`i$getv key
    di:drawItem[x;y;w;ih;sz;sel;]; di'[!#items; items]}
  / a slider: a thin track, a filled portion up to the value, and a handle. frac from ui.getv/rng.
  drawSlider:{[key;x;y;w;h]
    r:rng key; f:0.|1.&(getv[key]-r 0)%(r 1)-r 0
    ty:(y+0.5*h)-3.; hw:14.; hx:x+f*w-hw
    fillRect[x; ty; w; 6.; 0.82 0.82 0.86 1.]
    fillRect[x; ty; (hx-x)+0.5*hw; 6.; 0.22 0.45 0.95 1.]
    fillRect[hx; y+3.; hw; h-6.; 0.16 0.32 0.7 1.]}
  paintRow:{[W;i]
    x:(W`x)i; y:(W`y)i; w:(W`w)i; h:(W`h)i; sz:(W`sz)i
    bg:(W`bg)i; txt:(W`txt)i; a:(W`act)i; id:(W`id)i
    inp:a~`focus
    $[~bg~(); fillRect[x;y;w;h;bg]; 0]
    $[a~`slide; drawSlider[id;x;y;w;h]; 0]
    $[a~`list; drawList[id;x;y;w;sz]; 0]
    $[a~`canvas; canvasCB[x;y;w;h]; 0]
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

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
2: "lib/color.k"

  / ── theme: Tailwind palette (OKLCh → rgba via color.k `oklch`), swappable at runtime ──
  / A theme is a dict of role→rgba; `ui.setTheme t` rebinds the ui.* colour constants (the widget
  / constructors read these each frame, so a live switch reskins the whole kit next frame). Roles:
  / BLUE=accent, BLUED=accent-pressed, DARK=primary text/fg, WHITE=on-accent text, GREY=placeholder,
  / INBG/INFOC=input bg/focus, MENUBG/MENUHI=menu bg/hover, DISBG/DISFG=disabled, BADBG=invalid,
  / SELBG=selection, TRACK=slider·progress track, OK=progress fill, BG=page background.
ui.TROLES:`BLUE`BLUED`DARK`WHITE`GREY`INBG`INFOC`MENUBG`MENUHI`DISBG`DISFG`BADBG`SELBG`TRACK`OK`BG
ui.themeLight: ui.TROLES! oklch'(
  Blue600; Blue700; Slate900; White; Slate400; White; Blue50; White; Blue50
  Slate200; Slate400; Red100; Blue100; Slate200; Emerald600; Slate50 )
ui.themeDark: ui.TROLES! oklch'(
  Blue500; Blue600; Slate100; White; Slate500; Slate800; Slate700; Slate800; Slate700
  Slate800; Slate600; Red950; Blue900; Slate700; Emerald500; Slate950 )
ui.setTheme:{[t]
  ui.BLUE::t`BLUE; ui.BLUED::t`BLUED; ui.DARK::t`DARK; ui.WHITE::t`WHITE; ui.GREY::t`GREY
  ui.INBG::t`INBG; ui.INFOC::t`INFOC; ui.MENUBG::t`MENUBG; ui.MENUHI::t`MENUHI
  ui.DISBG::t`DISBG; ui.DISFG::t`DISFG; ui.BADBG::t`BADBG; ui.SELBG::t`SELBG
  ui.TRACK::t`TRACK; ui.OK::t`OK; ui.BG::t`BG}
ui.setTheme ui.themeLight                          / default: light
ui.CW:0.6                                       / monospace advance / em (FiraCode)
ui.KEYS:`t`w`h`grow`dir`gap`pad`kids`id`bg`txt`fg`sz`act

ui.FONT:()
ui.setFont:{[f] ui.FONT::f}
ui.fnt:{[] ui.FONT}
ui.measure:{[sz;s] (#s)*sz*ui.CW}                  / text width px (monospace ⇒ exact)

  / ── widget row (a 10-tuple; rect grouped to dodge ink's 8-param lambda cap) ────
ui.mkw:{[id;rect;bg;txt;fg;sz;act] (id;rect 0;rect 1;rect 2;rect 3;bg;txt;fg;sz;act)}
ui.build:{[rows] ui.KEYSW! +rows}
ui.KEYSW:`id`x`y`w`h`bg`txt`fg`sz`act

  / ── interaction state (keyed by widget id) ───────────────────────────────────
ui.buf:(,`none)!,""                             / id → text buffer / selected value
ui.opts:(,`none)!,()                            / id → select option list
ui.val:(,`none)!,0.                             / id → numeric value (sliders)
ui.rng:(,`none)!,0. 1.                          / id → (min;max) for sliders
ui.focus:`none                                  / focused input id
ui.open:`none                                   / open dropdown id
ui.drag:`none                                   / slider being dragged (`none = none)
ui.dragx:0.; ui.dragw:0.                           / dragged slider's track x / width
ui.caret:0                                      / caret column in the focused buffer
ui.get:{[k] $[k in !ui.buf; ui.buf k; ""]}
ui.set:{[k;s] ui.buf[k]:: s}
ui.getv:{[k] $[k in !ui.val; ui.val k; 0.]}
ui.setv:{[k;x] ui.val[k]:: x}
ui.isFocus:{[k] ui.focus~k}
ui.setFocus:{[k] ui.focus::k; ui.caret:: #ui.get k}       / focus an input from the app, caret at end
ui.regOpts:{[k;os] ui.opts[k]:: os}
ui.regRng:{[k;r] ui.rng[k]:: r}

  / ── leaves (each returns a node dict) ────────────────────────────────────────
ui.box:{[color] ui.KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();`box;color;"";ui.DARK;0.;`nop)}
ui.label:{[s] ui.KEYS!(`leaf;(ui.measure[18.;s])+4.;26.;0.;`row;0.;0.;();`lbl;();s;ui.DARK;18.;`nop)}
ui.button:{[s;act] ui.KEYS!(`leaf;(ui.measure[16.;s])+28.;36.;0.;`row;0.;0.;();`btn;ui.BLUE;s;ui.WHITE;16.;act)}
ui.spacer:{[] ui.KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();`sp;();"";ui.DARK;0.;`nop)}
  / A focusable text input `w` px wide, bound to buffer ui.get/ui.set[key]. act=`focus marks it.
ui.input:{[key;w;ph]
    s:ui.get key; foc:ui.isFocus key; empty:(s~"")&~foc
    ui.KEYS!(`leaf;w;34.;0.;`row;0.;0.;();key;$[foc;ui.INFOC;ui.INBG];$[empty;ph;s];$[empty;ui.GREY;ui.DARK];16.;`focus)}
  / A dropdown bound to buffer ui.get/ui.set[key]. Click opens a menu (an overlay, ui.overlay);
  / picking writes the value. act=`open marks the box.
ui.select:{[key;w;options]
    ui.regOpts[key;options]
    ui.KEYS!(`leaf;w;34.;0.;`row;0.;0.;();key;$[ui.open~key;ui.INFOC;ui.INBG];(ui.get key)," v";ui.DARK;16.;`open)}
  / A slider `w` px wide bound to ui.getv/ui.setv[key] over [mn;mx]. Click/drag the track to set.
ui.slider:{[key;w;mn;mx] ui.regRng[key;mn,mx]; ui.KEYS!(`leaf;w;28.;0.;`row;0.;0.;();key;();"";ui.DARK;0.;`slide)}
  / A progress gauge (fraction 0..1), `w`×`h` — pure flexbox: a fill box grows to `frac` of a track.
ui.progress:{[frac;w;h] ui.sized[w;h; ui.bg[ui.TRACK; ui.row[0.; (
    ui.grow[1e-4|frac; ui.box[ui.OK]] ; ui.grow[1e-4|1.-frac; ui.spacer[]] )]]]}
  / A selectable list box `w`×`h` showing `items` (strings). Click an item to select it; the
  / selected index is ui.getv/ui.setv[key]. act=`list; painted by drawList (highlight + text rows).
ui.list:{[key;items;w;h] ui.regOpts[key;items]; ui.KEYS!(`leaf;w;h;0.;`row;0.;0.;();key;ui.INBG;"";ui.DARK;16.;`list)}
  / A custom-draw canvas that fills its slot. `ui.onCanvas[fn]` sets a paint callback fn[x;y;w;h]
  / (rect in framebuffer px, called during paint); a click stores its position in ui.cvx/ui.cvy and
  / fires `canvas so the app can act on it.
ui.canvasCB:{[x;y;w;h] 0}
ui.onCanvas:{[fn] ui.canvasCB::fn}
ui.cvx:0.; ui.cvy:0.
ui.canvas:{[key] ui.KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();key;ui.INBG;"";ui.DARK;0.;`canvas)}
  / A grid cell `w`×`h` showing `label`, highlighted when `hl`. Clicking fires `id (the app uses the
  / cell's own name as the action). For spreadsheets / tabular pickers.
ui.cell:{[id;label;w;h;hl] ui.KEYS!(`leaf;w;h;0.;`row;0.;0.;();id;$[hl;ui.SELBG;ui.WHITE];label;ui.DARK;15.;id)}

  / ── containers ───────────────────────────────────────────────────────────────
ui.row:{[g;kids] ui.KEYS!(`box;0.;0.;0.;`row;g;0.;kids;`row;();"";ui.DARK;0.;`nop)}
ui.col:{[g;kids] ui.KEYS!(`box;0.;0.;0.;`col;g;0.;kids;`col;();"";ui.DARK;0.;`nop)}

  / ── combinators (amend one node field; chainable) ────────────────────────────
ui.grow:{[g;nd] @[nd;`grow;:;g]}
ui.pad:{[p;nd] @[nd;`pad;:;p]}
ui.sized:{[w;h;nd] @[@[nd;`w;:;w];`h;:;h]}
ui.gap:{[g;nd] @[nd;`gap;:;g]}
ui.bg:{[c;nd] @[nd;`bg;:;c]}
ui.disabled:{[nd] @[@[@[nd;`bg;:;ui.DISBG];`fg;:;ui.DISFG];`act;:;`nop]}
ui.invalid:{[nd] @[nd;`bg;:;ui.BADBG]}
  / ── flat styling: set MANY node fields in one call, no combinator onion ─────────
  / `ui.sty[nd; d]` amends node `nd` with every (field→value) in dict `d`. Since the
  / bg/pad/sized/… combinators each just amend ONE field and return the same node,
  / three nested calls set three fields; this collapses them: e.g.
  /   ui.sty[ui.col[18.; kids]; `bg`pad!(Slate50; 40.)]
  / replaces  ui.bg[Slate50; ui.pad[40.; ui.col[18.; kids]]]  (identical result).
ui.sty:{[nd;d] {@[x; *y; :; *|y]}/[nd; +(!d;. d)]}

  / ── natSize: intrinsic content size, bottom-up ───────────────────────────────
ui.gwf:{x`w}; ui.ghf:{x`h}; ui.ggf:{x`grow}; ui.gwf0:{x 0}; ui.ghf0:{x 1}
  / a leaf reports its own size; a container computes from children UNLESS `sized` set an explicit
  / w/h (>0), which then wins — otherwise a sized container (e.g. a progress track) collapses to 0.
ui.natSize:{[nd] $[(nd`t)~`leaf; (nd`w; nd`h); ui.nbx nd]}
ui.nbx:{[nd] nb:ui.natBox nd; ($[(nd`w)>0.; nd`w; nb 0]; $[(nd`h)>0.; nd`h; nb 1])}
ui.natBox:{[nd] $[0=#nd`kids; (2.*nd`pad; 2.*nd`pad); ui.natBox2 nd]}
ui.natBox2:{[nd]
    p:nd`pad; g:nd`gap; n:#nd`kids; szs:ui.natSize'nd`kids
    ws:ui.gwf0'szs; hs:ui.ghf0'szs
    $[(nd`dir)~`row; ((+/ws)+(2.*p)+g*n-1; (|/hs)+2.*p); ((|/ws)+2.*p; (+/hs)+(2.*p)+g*n-1)]}

  / ── solve: tree → flat rows, scaled by dpr `s` to framebuffer px ──────────────
ui.exPre:{(+\x)-x}
  / emit a row unless it's a pure spacer (no bg, no text, inert) — a slider has none of those but IS interactive.
ui.leafRows:{[nd;x;y;w;h;s]
    $[(((nd`bg)~())&(nd`txt)~"")&(nd`act)~`nop; (); ,ui.mkw[nd`id; s*x,y,w,h; nd`bg; nd`txt; nd`fg; s*nd`sz; nd`act]]}
ui.boxRows:{[nd;x;y;w;h;s]
    hdr:$[(nd`bg)~(); (); ,ui.mkw[nd`id; s*x,y,w,h; nd`bg; ""; nd`fg; 0.; `nop]]
    hdr,$[0=#nd`kids; (); ui.layoutKids[nd;x;y;w;h;s]]}
ui.csz:{[avail;k] $[k>0.; avail&k; avail]}
ui.mainf:{[rw;nats] $[rw; ui.gwf0'nats; ui.ghf0'nats]}
ui.crossf:{[rw;nats] $[rw; ui.ghf0'nats; ui.gwf0'nats]}
ui.layoutKids:{[nd;x;y;w;h;s]
    p:nd`pad; g:nd`gap; rw:(nd`dir)~`row; kids:nd`kids; n:#kids
    ix:x+p; iy:y+p; iw:w-2.*p; ih:h-2.*p
    mainAv:$[rw;iw;ih]; crossAv:$[rw;ih;iw]
    nats:ui.natSize'kids
    base:ui.mainf[rw;nats]; grows:ui.ggf'kids
    slack:0.|(mainAv-(+/base))-g*0|n-1
    gs:+/grows
    sizes:base+$[gs>0.; slack*grows%gs; n#0.]
    starts:$[rw;ix;iy]+(ui.exPre sizes)+g*!n
    crossSz:ui.csz[crossAv;]'ui.crossf[rw;nats]
    crossPos:$[rw;iy;ix]+0.5*crossAv-crossSz
    X:$[rw; starts; crossPos]; Y:$[rw; crossPos; starts]
    W:$[rw; sizes; crossSz];   H:$[rw; crossSz; sizes]
    ,/ui.solve'[kids;X;Y;W;H;n#s]}
ui.solve:{[nd;x;y;w;h;s] $[(nd`t)~`leaf; ui.leafRows[nd;x;y;w;h;s]; ui.boxRows[nd;x;y;w;h;s]]}

  / ── overlay: the open dropdown's menu rows, stacked below its box (framebuffer px) ──
ui.mkOpt:{[x;yb;w;h;sz;key;j;s] ui.mkw[key; x,(yb+h*j),w,h; ui.MENUBG; s; ui.DARK; sz; `pick]}
ui.menuRows:{[W]
    i:*&((ui.open=W`id)&`open=W`act)
    x:(W`x)@i; h:(W`h)@i; os:ui.opts ui.open
    ui.mkOpt[x; ((W`y)@i)+h; (W`w)@i; h; (W`sz)@i; ui.open;]'[!#os; os]}
ui.overlay:{[W] $[ui.open~`none; (); ui.menuRows W]}

  / Solve `nd` over the viewport; append any open menu as trailing overlay rows.
ui.NOVL:0
ui.run:{[nd;props]
    s:props`dpr
    rows:ui.solve[nd; 0.; 0.; (props`width)%s; (props`height)%s; s]
    W:ui.build rows
    ov:ui.overlay W
    ui.NOVL::#ov
    ui.build rows,ov}

  / ── hit-test (vectorised): topmost = last row ────────────────────────────────
ui.hit:{[W;px;py]
    x:W`x; y:W`y; w:W`w; h:W`h
    i:&((~px<x)&(px<x+w))&(~py<y)&(py<y+h)
    $[#i; *|i; -1]}

  / ── click dispatch: focus / open menu / pick option / defocus, return app acts ─
ui.caretCol:{[px;x0;sz;s] 0|(_0.5+(px-x0)%sz*ui.CW)&#s}
ui.doFocus:{[W;i;px] k:(W`id)@i; ui.focus::k; ui.open::`none; ui.caret::ui.caretCol[px; ((W`x)@i)+6.; (W`sz)@i; ui.get k]; `nop}
ui.toggleOpen:{[W;i] k:(W`id)@i; ui.open:: $[ui.open~k; `none; k]; ui.focus::`none; `nop}
ui.pickOpt:{[W;i] ui.set[(W`id)@i; (W`txt)@i]; ui.open::`none; `nop}
  / start dragging a slider: capture its track x/width, jump the value to the click x.
ui.slideTo:{[px] r:ui.rng ui.drag; f:0.|1.&(px-ui.dragx)%ui.dragw; ui.setv[ui.drag; (r 0)+f*(r 1)-r 0]}
ui.doSlide:{[W;i;px] ui.drag::(W`id)@i; ui.dragx::(W`x)@i; ui.dragw::(W`w)@i; ui.slideTo px; `nop}
ui.hitAct:{[W;i] ui.focus::`none; ui.open::`none; (W`act)@i}
  / click a list row → select the item under the cursor (index = row from the top, by geometry).
ui.ITEMK:1.7                                    / list item height / font size
ui.doList:{[W;i;py] k:(W`id)@i; n:#ui.opts k; $[n=0; `nop; ui.setList[W;i;py;k;n]]}
ui.setList:{[W;i;py;k;n] ih:ui.ITEMK*(W`sz)@i; ui.setv[k; 0.+0|(n-1)&_(py-(W`y)@i)%ih]; `nop}
ui.doCanvas:{[p] ui.cvx::p 0; ui.cvy::p 1; ui.focus::`none; `canvas}
ui.onHit:{[W;i;p]
    a:(W`act)@i
    $[a~`focus; ui.doFocus[W;i;p 0]; a~`open; ui.toggleOpen[W;i]; a~`pick; ui.pickOpt[W;i]; a~`slide; ui.doSlide[W;i;p 0]; a~`list; ui.doList[W;i;p 1]; a~`canvas; ui.doCanvas[p]; ui.hitAct[W;i]]}
ui.defocus:{[] ui.focus::`none; ui.open::`none; `nop}
ui.dispatchPt:{[W;p] i:ui.hit[W;p 0;p 1]; $[i<0; ui.defocus[]; ui.onHit[W;i;p]]}
ui.mouseActs:{[W;E]
    i:&((`mouse=E`kind)&(1=E`down))&(0=E`code)
    ui.dispatchPt[W;]'+((E`x)@i;(E`y)@i)}
  / a mouse RELEASE ends any drag; continuous drag reads props`mx each frame.
ui.releaseDrag:{[E] $[0<#&(`mouse=E`kind)&0=E`down; ui.drag::`none; 0]}
ui.dragUpdate:{[props] $[ui.drag~`none; 0; ui.slideTo props`mx]}

  / ── editing the focused buffer (mechanics from demo/edit.k) ───────────────────
ui.insChDo:{[cp] k:ui.focus; s:ui.get k; c:ui.caret; ui.set[k; (c#s),(`c$cp),(c_s)]; ui.caret::c+1}
ui.insCh:{[cp] $[ui.focus~`none; 0; ui.insChDo cp]}
ui.backDo:{[] k:ui.focus; s:ui.get k; c:ui.caret; ui.set[k; ((c-1)#s),(c_s)]; ui.caret::c-1}
ui.delDo:{[] k:ui.focus; s:ui.get k; c:ui.caret; ui.set[k; (c#s),((c+1)_s)]}
ui.back:{[] $[ui.caret>0; ui.backDo[]; 0]}
ui.del:{[] $[ui.caret<#ui.get ui.focus; ui.delDo[]; 0]}
ui.left:{[] $[ui.caret>0; ui.caret::ui.caret-1; 0]}
ui.right:{[] $[ui.caret<#ui.get ui.focus; ui.caret::ui.caret+1; 0]}
ui.home:{[] ui.caret::0}
ui.end:{[] ui.caret:: #ui.get ui.focus}
ui.editKey:{[k] $[k=259;ui.back[]; k=261;ui.del[]; k=263;ui.left[]; k=262;ui.right[]; k=268;ui.home[]; k=269;ui.end[]; 0]}
ui.editText:{[E] pf:{ui.insCh x}; pf' 0+(E`code)@&`text=E`kind}
ui.editKeys:{[E] pf:{ui.editKey x}; pf' 0+(E`code)@&(`key=E`kind)&1=E`down}
ui.keys:{[E] $[ui.focus~`none; 0; ui.keysDo E]}
ui.keysDo:{[E] ui.editText E; ui.editKeys E; 0}

  / One entry point per frame: clicks (focus/menu/slider + app actions), drag, keyboard.
ui.frame:{[W;props] E:props`events; a:ui.mouseActs[W;E]; ui.releaseDrag E; ui.dragUpdate props; ui.keys E; a}

  / ── paint ────────────────────────────────────────────────────────────────────
ui.fillRect:{[x;y;w;h;c] cnv.rect[x;y;w;h]; cnv.fill cnv.rgba[c 0;c 1;c 2;c 3]}
ui.drawTxt:{[x;y;sz;s;c] cnv.moveTo[x;y]; cnv.text[ui.FONT; sz; s; cnv.rgba[c 0;c 1;c 2;c 3]]}
ui.drawCaret:{[tx;y;h;sz;col] cx:tx+col*sz*ui.CW; cnv.rect[cx; y+0.15*h; 2.; 0.7*h]; cnv.fill cnv.rgba[ui.BLUE 0;ui.BLUE 1;ui.BLUE 2;ui.BLUE 3]}
  / a list box: one text row per item; the selected row (ui.getv[key]) gets a highlight behind it.
  / (ui.SELBG is part of the theme — see ui.setTheme up top.)
ui.drawItem:{[x;y;w;ih;sz;sel;j;s]
    $[j=sel; ui.fillRect[x; y+ih*j; w; ih; ui.SELBG]; 0]
    ui.drawTxt[x+8.; (y+ih*j)+0.66*ih; sz; s; ui.DARK]}
ui.drawList:{[key;x;y;w;sz]
    items:ui.opts key; ih:ui.ITEMK*sz; sel:`i$ui.getv key
    di:ui.drawItem[x;y;w;ih;sz;sel;]; di'[!#items; items]}
  / a slider: a thin track, a filled portion up to the value, and a handle. frac from ui.getv/rng.
ui.drawSlider:{[key;x;y;w;h]
    r:ui.rng key; f:0.|1.&(ui.getv[key]-r 0)%(r 1)-r 0
    ty:(y+0.5*h)-3.; hw:14.; hx:x+f*w-hw
    ui.fillRect[x; ty; w; 6.; ui.TRACK]
    ui.fillRect[x; ty; (hx-x)+0.5*hw; 6.; ui.BLUE]
    ui.fillRect[hx; y+3.; hw; h-6.; ui.BLUED]}
ui.paintRow:{[W;i]
    x:(W`x)i; y:(W`y)i; w:(W`w)i; h:(W`h)i; sz:(W`sz)i
    bg:(W`bg)i; txt:(W`txt)i; a:(W`act)i; id:(W`id)i
    inp:a~`focus
    $[~bg~(); ui.fillRect[x;y;w;h;bg]; 0]
    $[a~`slide; ui.drawSlider[id;x;y;w;h]; 0]
    $[a~`list; ui.drawList[id;x;y;w;sz]; 0]
    $[a~`canvas; ui.canvasCB[x;y;w;h]; 0]
    center:(~bg~())&(~inp)&~a~`open              / buttons centre; inputs/selects/labels left
    tx:$[center; x+0.5*w-ui.measure[sz;txt]; x+6.]
    by:y+$[h>0.; (0.5*h)+0.34*sz; sz]
    $[~txt~""; ui.drawTxt[tx; by; sz; txt; (W`fg)i]; 0]
    $[inp&(id~ui.focus); ui.drawCaret[x+6.; y; h; sz; ui.caret]; 0]}
ui.paintRows:{[W;is] pr:ui.paintRow[W;]; pr'is}
ui.paint:{[W] ui.paintRows[W; !#W`x]}

  / draw: main UI as render 1; any overlay (NOVL trailing rows) as render 2, whose fills occlude
  / render 1's text (canvas draws fills-then-text per render, so a 2nd render composites on top).
ui.draw:{[W;w;h]
    n:#W`x; k:n-ui.NOVL
    cnv.new[]; ui.paintRows[W; !k]; cnv.render[w;h]
    $[ui.NOVL>0; ui.drawOv[W;k;n;w;h]; 0]}
ui.drawOv:{[W;k;n;w;h] cnv.new[]; ui.paintRows[W; k+!n-k]; cnv.render[w;h]}

/ lib/layout.k — a flexbox-style layout over lib/ui.k. You describe the UI as a TREE of nodes
/ (row/col containers + leaves); `solve` does ONE recursive pass assigning rects, then emits the
/ flat ui row-table for hit-test/paint. No hard-coded x/y/w/h — children size to content or flex
/ to fill. Everything is in LOGICAL units; solve takes the device pixel ratio `s` and scales the
/ emitted geometry to framebuffer px (the cursor's space), so DPI just works.
/
/ Load with:  2: "lib/layout.k"
/
/ A NODE is a dict: t(`leaf/`box) w h grow dir(`row/`col) gap pad kids id bg txt fg sz act.
/ Leaves carry paint data (bg/txt/fg/sz/act) + an intrinsic size; containers carry kids.
/ MAIN axis = the container's dir; children lay out along it (fixed sizes first, then `grow`
/ children share the slack by weight — a prefix-sum gives their offsets). CROSS axis stretches.

2: "lib/ui.k"

\d layout row col box label button input spacer grow pad sized gap bg solve run natSize
  BLUE: 0.22 0.45 0.95 1.; DARK: 0.10 0.10 0.12 1.; WHITE: 1. 1. 1. 1.; PANEL: 0.96 0.96 0.97 1.
  INBG: 1. 1. 1. 1.; INFOC: 0.90 0.94 1. 1.; GREY: 0.6 0.6 0.66 1.
  KEYS: `t`w`h`grow`dir`gap`pad`kids`id`bg`txt`fg`sz`act

  / ── Leaves ───────────────────────────────────────────────────────────────────
  / A filled rectangle that grows to fill its slot (e.g. a panel/background).
  box:{[color] KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();`box;color;"";DARK;0.;`nop)}
  / A text label; intrinsic size = measured text (FiraCode is monospace).
  label:{[s] KEYS!(`leaf;(ui.measure[18.;s])+4.;26.;0.;`row;0.;0.;();`lbl;();s;DARK;18.;`nop)}
  / A clickable button sized to its caption; clicking fires `act`.
  button:{[s;act] KEYS!(`leaf;(ui.measure[16.;s])+28.;36.;0.;`row;0.;0.;();`btn;BLUE;s;WHITE;16.;act)}
  / A focusable text input `w` px wide, bound to buffer ui.get/ui.set[key]. Click to focus +
  / place caret; type to edit. Shows `ph` (grey) when empty and unfocused. act=`focus marks it.
  input:{[key;w;ph]
    s:ui.get key; foc:ui.isFocus key; empty:(s~"")&~foc
    KEYS!(`leaf;w;34.;0.;`row;0.;0.;();key;$[foc;INFOC;INBG];$[empty;ph;s];$[empty;GREY;DARK];16.;`focus)}
  / A flexible empty gap that eats slack (grow=1, draws nothing).
  spacer:{[] KEYS!(`leaf;0.;0.;1.;`row;0.;0.;();`sp;();"";DARK;0.;`nop)}

  / ── Containers ───────────────────────────────────────────────────────────────
  / kids laid left→right (row) / top→bottom (col), `gap` px between. Natural size (grow=0);
  / give them a `grow` to fill, a `bg` to paint a background rect behind their children.
  row:{[g;kids] KEYS!(`box;0.;0.;0.;`row;g;0.;kids;`row;();"";DARK;0.;`nop)}
  col:{[g;kids] KEYS!(`box;0.;0.;0.;`col;g;0.;kids;`col;();"";DARK;0.;`nop)}

  / ── Combinators (amend one field; chainable) ─────────────────────────────────
  grow:{[g;nd] @[nd;`grow;:;g]}      / set flex weight (main-axis slack share)
  pad:{[p;nd] @[nd;`pad;:;p]}        / inner padding
  sized:{[w;h;nd] @[@[nd;`w;:;w];`h;:;h]}
  gap:{[g;nd] @[nd;`gap;:;g]}
  bg:{[c;nd] @[nd;`bg;:;c]}          / background colour (containers)

  / ── natSize: intrinsic (content) size, bottom-up ─────────────────────────────
  gwf:{x`w}; ghf:{x`h}; ggf:{x`grow}
  natSize:{[nd] $[(nd`t)~`leaf; (nd`w; nd`h); natBox nd]}
  natBox:{[nd] $[0=#nd`kids; (2.*nd`pad; 2.*nd`pad); natBox2 nd]}
  natBox2:{[nd]
    p:nd`pad; g:nd`gap; n:#nd`kids; szs:natSize'nd`kids
    ws:gwf0'szs; hs:ghf0'szs
    $[(nd`dir)~`row
      ; ((+/ws)+(2.*p)+g*n-1; (|/hs)+2.*p)
      ; ((|/ws)+2.*p;         (+/hs)+(2.*p)+g*n-1)]}
  gwf0:{x 0}; ghf0:{x 1}

  / ── solve: rect assignment → flat ui rows (scaled by dpr `s` to framebuffer px) ──
  exPre:{(+\x)-x}                    / exclusive prefix sum (offset of each item)
  / A leaf → 0 or 1 ui rows. Empty (no fill, no text: a spacer) emits nothing.
  leafRows:{[nd;x;y;w;h;s]
    $[((nd`bg)~())&(nd`txt)~""; (); ,ui.mkw[nd`id; s*x,y,w,h; nd`bg; nd`txt; nd`fg; s*nd`sz; nd`act]]}
  boxRows:{[nd;x;y;w;h;s]
    hdr:$[(nd`bg)~(); (); ,ui.mkw[nd`id; s*x,y,w,h; nd`bg; ""; nd`fg; 0.; `nop]]
    hdr,$[0=#nd`kids; (); layoutKids[nd;x;y;w;h;s]]}
  / cross size: a kid with a fixed cross dim keeps it (clamped) and CENTRES; a 0 (containers,
  / spacers, bg boxes) fills the cross axis. main: intrinsic sizes first, grow kids split slack.
  csz:{[avail;k] $[k>0.; avail&k; avail]}
  mainf:{[row;nats] $[row; gwf0'nats; ghf0'nats]}
  crossf:{[row;nats] $[row; ghf0'nats; gwf0'nats]}
  layoutKids:{[nd;x;y;w;h;s]
    p:nd`pad; g:nd`gap; row:(nd`dir)~`row; kids:nd`kids; n:#kids
    ix:x+p; iy:y+p; iw:w-2.*p; ih:h-2.*p
    mainAv:$[row;iw;ih]; crossAv:$[row;ih;iw]
    nats:natSize'kids
    base:mainf[row;nats]; grows:ggf'kids
    slack:0.|(mainAv-(+/base))-g*0|n-1
    gs:+/grows
    sizes:base+$[gs>0.; slack*grows%gs; n#0.]
    starts:$[row;ix;iy]+(exPre sizes)+g*!n
    crossSz:csz[crossAv;]'crossf[row;nats]
    crossPos:$[row;iy;ix]+0.5*crossAv-crossSz
    X:$[row; starts; crossPos]; Y:$[row; crossPos; starts]
    W:$[row; sizes; crossSz];   H:$[row; crossSz; sizes]
    ,/solve'[kids;X;Y;W;H;n#s]}
  solve:{[nd;x;y;w;h;s] $[(nd`t)~`leaf; leafRows[nd;x;y;w;h;s]; boxRows[nd;x;y;w;h;s]]}
  / Solve `nd` over the whole framebuffer viewport and build the archetype ready for a frame.
  run:{[nd;props] ui.build solve[nd; 0.; 0.; (props`width)%props`dpr; (props`height)%props`dpr; props`dpr]}
\d

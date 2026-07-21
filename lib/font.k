/ lib/font.k — native sfnt font reader + outline/shape/metrics
/
/ font.read "path" → a LIST of face dicts (one per face; a TTC yields several,
/ a single TTF/OTF yields a one-element list — uniform API across flavours).
/ Each face dict is keyed by normalized table name → that table's value:
/   head  maxp  hhea  hmtx  loca  post  name  OS2  cmap  cvt  fpgm  prep  gasp
\d font read outline outlines quads shape scale metrics upm glyph nameID family subfamily fullName
  so:"./zig-out/lib/libfont.dylib"
  read:so 2:(`ReadFont; 1)            / "path" → L of face dicts
  upm:{[f] f[`head]`upm}                                          / units per em
  scale:{[f;sz] sz % upm f}                                         / em → pixel factor
  metrics:{[f;sz] (scale[f;sz]) * f[`hhea]`ascent`descent`lineGap}    / → (ascent;descent;lineGap) px
  / First string for a nameID (1=family 2=subfamily 4=full 6=postscript), else "".
  nameID:{[f;id] nm: f`name; v: (nm`value)@&id=nm`nameID; $[#v; *v; ""]}
  family:{[f] nameID[f;1]}
  subfamily:{[f] nameID[f;2]}
  fullName:{[f] nameID[f;4]}
  / Single codepoint → glyph id via the cmap (0=.notdef when unmapped).
  glyph:{[f;cp] c: f`cmap; cps: c`cp; $[cp in cps; (c`gid) cps?cp; 0]}
  / A whole char string → glyph ids (no ligatures/kerning). Vectorized: `?` gives
  / #cps for an absent codepoint, indexing the appended .notdef gid 0.
  shape:{[f;s]c:f`cmap;((c`gid),0) @ (c`cp)?`i$s}
  / outline  f gid sz  → L of flat F contours (pixel-space, y-flipped). Feed each
  / to gpu.tessellate. outlines does the whole gid vector at once.
  outline:{[f;gid;sz]$[`CFF in !f;cff2.outline;glyf.outline][f;scale[f;sz];gid]}
  outlines:{[f;sz;gids] $[`CFF in !f;cff2.outline;glyf.outline][f;scale[f;sz]]'gids}
  / quads  f gid sz  → L of flat F contours of RAW quadratic control points (glyf native;
  / CFF cubics are split to 2 quads each in the charstring interpreter — cff2.quads).
  / [x0 y0 cx cy x1 y1 …] (pixel-space, y-flipped), for GPU analytic coverage. ~8× fewer
  / segments than `outline`, and truly resolution-independent when fed to a quadratic shader.
  quads:{[f;gid;sz] $[`CFF in !f;cff2.quads;glyf.quads][f;scale[f;sz];gid]}
/ ── font.glyf — TrueType quadratic (glyf) outline flattening ────────────────
/ glyf stores quadratic Béziers as on/off-curve points; two consecutive
/ off-curve points imply an on-curve midpoint. Everything below flattens that to
/ (x;y) point lists in FONT UNITS, resolves composite glyphs, then scales+flips.
/ `outline` (flattened polylines) and `quads` (raw quadratic control triples) public.
\d font.glyf outline quads
  midway: {0.5*x+y}                                                    / midpoint of two points
  / Flatten one quad a(on)→b(ctrl)→c(on) over QN sample times, vectorized.
  subdivide:{[a;b;c]
    QN:8; tt:(1.+!QN)%QN;
    u:1.-tt; u2:u*u; utt2:2.*u*tt; tt2:tt*tt
    +((u2*a 0)+(utt2*b 0)+tt2*c 0
      (u2*a 1)+(utt2*b 1)+tt2*c 1)}
  / fold step over ((x;y);on) entries. state = (out; cur; pend; hp).
  fpOn: {[st;p]
    $[st 3;(st[0],subdivide[st 1;st 2;p]; p; st 2; 0);
           (st[0],,p; p; st 2; 0)]}
  fpOff:{[st;p]
    $[st 3;(st[0],subdivide[st 1;st 2;midway[st 2;p]];midway[st 2;p]; p; 1);
      (st 0; st 1; p; 1)]}
  fpStep: {[st;e] $[e 1; fpOn[st;e 0]; fpOff[st;e 0]]}
  fpStart:{[pts;on;hasOn] $[hasOn; pts on?1; midway[pts(-1+#pts); pts 0]]}
  fpSeq:  {[pr;on;hasOn] $[hasOn; 1 _ (((on?1) _ pr),((on?1)#pr)); pr]}
  / flatten one contour c=(pts;on) → list of (x;y) points (font units).
  flatC:{[c]
    pts: c 0; on: c 1;
    pr: +(pts;on);
    hasOn: 1 in on;
    start: fpStart[pts;on;hasOn];
    seq: fpSeq[pr;on;hasOn];
    acc: (,start; start; (0.;0.); 0) fpStep/ seq
    $[acc 3; (acc 0),subdivide[acc 1;acc 2;start]; acc 0]}
  / simple glyph dict → list of contours, each (pts;on); split with `_` cut.
  simpleC:{[g]
    pts: +(0.+(g`x); 0.+(g`y));
    starts: 0,1+-1_(g`ends);
    +((starts_pts); (starts_g`on))}
  contours: {[g] $[0=#g`ends; (); simpleC g]}
  / ── composite glyphs + recursion (face dict `f` threaded as a plain arg) ───
  xform: {[xx;xy;yx;yy;dx;dy;c]
    xs: {x 0}'c;
    ys: {x 1}'c; +(((xx*xs)+(yx*ys)+dx); ((xy*xs)+(yy*ys)+dy))}
  compRow: {[f;r] xf: xform[r 3; r 4; r 5; r 6; r 1; r 2]; xf' resolve[f; r 0]}
  compositeG:{[f;g]
    ps: g`parts;
    rows: +((ps`glyph); 0.+(ps`dx); 0.+(ps`dy); ps`xx; ps`xy; ps`yx; ps`yy);
    ,/ compRow[f]'rows}
  / resolved, flattened contours of a glyph in font units (composites recursed).
  resolve:{[f;gid]
    g: (f`glyf) gid;
    $[`parts in !g; compositeG[f;g]; flatC' contours g]}
  / scale to pixels + flip y (font y-up → screen y-down) → flat F [x,y,x,y,…].
  emit: {[sc;c] xs: {x 0}'c; ys: {x 1}'c; ,/ +((sc*xs); (-sc)*ys)}
  outline: {[f;sc;gid] emit[sc]' resolve[f;gid]}
  / ── Raw quadratic control points (for GPU analytic coverage; lib/slug.k) ─────
  / Same walk as flatC, but instead of subdividing each quad it emits the control
  / TRIPLE (on; ctrl; on) as 6 floats — a contour becomes a flat buffer of quads
  / [x0 y0 cx cy x1 y1 …]. Straight runs (on→on) get a midpoint control (degenerate
  / quad = a line). ~8× fewer segments than the flattened outline.
  seg3: {[a;b;c] a,b,c}
  rOn: {[st;p]
    $[st 3;(st[0],seg3[st 1;st 2;p]; p; st 2; 0);
           (st[0],seg3[st 1;midway[st 1;p];p]; p; st 2; 0)]}
  rOff:{[st;p]
    $[st 3;(st[0],seg3[st 1;st 2;midway[st 2;p]]; midway[st 2;p]; p; 1);
           (st 0; st 1; p; 1)]}
  rStep: {[st;e] $[e 1; rOn[st;e 0]; rOff[st;e 0]]}
  rawC: {[c]
    pts:c 0; on:c 1; pr:+(pts;on); hasOn:1 in on
    start:fpStart[pts;on;hasOn]; seq:fpSeq[pr;on;hasOn]
    acc:(0#0.; start; 0. 0.; 0) rStep/ seq
    cur:acc 1
    $[acc 3; (acc 0),seg3[cur;acc 2;start]; (acc 0),seg3[cur;midway[cur;start];start]]}
  / affine a flat [x y …] segment buffer (composite recursion; no closure via each-multi)
  xformBuf:{[xx;xy;yx;yy;dx;dy;buf]
    n:(#buf)div 2; ix:2*!n; xs:buf@ix; ys:buf@ix+1
    ,/+(((xx*xs)+(yx*ys)+dx); ((xy*xs)+(yy*ys)+dy))}
  compRowQ:{[f;r]
    bufs: quadsResolve[f; r 0]; nb:#bufs
    xformBuf'[nb#(r 3); nb#(r 4); nb#(r 5); nb#(r 6); nb#(r 1); nb#(r 2); bufs]}
  compositeQ:{[f;g]
    ps:g`parts
    rows:+((ps`glyph); 0.+(ps`dx); 0.+(ps`dy); ps`xx; ps`xy; ps`yx; ps`yy)
    ,/[compRowQ[f]'rows]}
  quadsResolve:{[f;gid]
    g:(f`glyf) gid
    $[`parts in !g; compositeQ[f;g]; rawC' contours g]}
  quads: {[f;sc;gid] emit2[sc]' quadsResolve[f;gid]}
  / scale + y-flip a flat quad buffer (control points are just points).
  emit2: {[sc;buf] n:(#buf)div 2; ix:2*!n; xs:buf@ix; ys:buf@ix+1; ,/+((sc*xs); (-sc)*ys)}
/ ── font.cff2 — PostScript / CFF Type-2 charstring outlines (in Zig) ────────
/ Returns the same shape as the glyf path (pixel-scaled, y-flipped). Only
/ `outline` is public.
\d font.cff2 outline quads
  so:   "./zig-out/lib/libfont.dylib"
  / (charstring_C; gsubrs_L; lsubrs_L; scale_f) → L of flat F contours.
  outline0: so 2:(`cffOutline; 1)
  / Same, but RAW quadratic control triples (cubics split to 2 quads) for the Slug shader.
  quads0:   so 2:(`cffQuads; 1)
  / Local subrs: non-CID `localSubrs`, or per-FD subrs picked by fdSelect (CID).
  lsubrs:{[c;gid]$[
    `localSubrs in !c; c`localSubrs;
    `fdLocalSubrs in !c; (c`fdLocalSubrs)@((c`fdSelect)gid);,()]}
  args:{[f;gid;sc] c:f`CFF; ((c`charStrings)gid; c`globalSubrs; lsubrs[c;gid]; sc)}
  outline:{[f;sc;gid] outline0 args[f;gid;sc]}
  quads:{[f;sc;gid] quads0 args[f;gid;sc]}

/ lib/font.k — native sfnt font reader + outline/shape/metrics
/
/ font.read "path" → a LIST of face dicts (one per face; a TTC yields several,
/ a single TTF/OTF yields a one-element list — uniform API across flavours).
/ Each face dict is keyed by normalized table name → that table's value:
/   head  maxp  hhea  hmtx  loca  post  name  OS2  cmap  cvt  fpgm  prep  gasp
\d font read outline outlines shape scale metrics upm glyph nameID family subfamily fullName
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
  / to tessellate. outlines does the whole gid vector at once.
  outline:{[f;gid;sz]$[`CFF in !f;cff2.outline;glyf.outline][f;scale[f;sz];gid]}
  outlines:{[f;sz;gids] $[`CFF in !f;cff2.outline;glyf.outline][f;scale[f;sz]]'gids}
/ ── font.glyf — TrueType quadratic (glyf) outline flattening ────────────────
/ glyf stores quadratic Béziers as on/off-curve points; two consecutive
/ off-curve points imply an on-curve midpoint. Everything below flattens that to
/ (x;y) point lists in FONT UNITS, resolves composite glyphs, then scales+flips.
/ Only `outline` is public.
\d font.glyf outline
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
/ ── font.cff2 — PostScript / CFF Type-2 charstring outlines (in Zig) ────────
/ Returns the same shape as the glyf path (pixel-scaled, y-flipped). Only
/ `outline` is public.
\d font.cff2 outline
  so:   "./zig-out/lib/libfont.dylib"
  / (charstring_C; gsubrs_L; lsubrs_L; scale_f) → L of flat F contours.
  outline0: so 2:(`cffOutline; 1)
  / Local subrs: non-CID `localSubrs`, or per-FD subrs picked by fdSelect (CID).
  lsubrs:{[c;gid]$[
    `localSubrs in !c; c`localSubrs;
    `fdLocalSubrs in !c; (c`fdLocalSubrs)@((c`fdSelect)gid);,()]}
  outline:{[f;sc;gid]
    c: f`CFF;
    outline0 ((c`charStrings)gid; c`globalSubrs; lsubrs[c;gid]; sc)}

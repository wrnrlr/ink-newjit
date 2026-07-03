/ lib/font.k — native sfnt font reader + outline/shape/metrics
/
/ Build first:  zig build font
/ Load with:    2: "lib/font.k"   (or just reference `font.read` etc — auto-loads)
/
/ font.read "path" → a LIST of face dicts (one per face; a TTC yields several,
/ a single TTF/OTF yields a one-element list — uniform API across flavours).
/
/ Each face dict is keyed by normalized table name → that table's normalized
/ value. Implemented so far:
/
/   head  maxp  hhea  hmtx  loca  post  name  OS2  cmap  cvt  fpgm  prep  gasp
/
/ Glyph flavour is `glyf` (TrueType outlines, with `loca`) vs `CFF`/`CFF2`
/ (PostScript outlines); font.outline dispatches on it. Only tables actually
/ present in the file appear in the dict.
/
/ Public API (all under the `font` namespace):
/   read outline outlines shape scale metrics upm glyph nameID family subfamily fullName
/
/ Style note: keep each $[...] on one line — a multi-line $[] used to hang the
/ parser and the tight one-line form is still the house style here.

\d font read outline outlines shape scale metrics upm glyph nameID family subfamily fullName

  so: "./zig-out/lib/libfont.dylib"
  read:        so 2:(`ReadFont;   1)   / "path" → L of face dicts
  cffOutline0: so 2:(`cffOutline; 1)   / (charstring_C; gsubrs_L; lsubrs_L; scale_f) → L of flat F contours

  / ── metrics ──────────────────────────────────────────────────────────────
  upm:     {[f] f[`head]`upm}                                      / units per em (em-square)
  scale:   {[f;sz] sz % upm f}                                     / em → pixel factor at size sz
  metrics: {[f;sz] (scale[f;sz]) * f[`hhea]`ascent`descent`lineGap}   / → (ascent; descent; lineGap) px

  / ── names / cmap ─────────────────────────────────────────────────────────
  / First string for a nameID (1=family 2=subfamily 4=full 6=postscript), else "".
  nameID:    {[f;id] nm: f`name; v: (nm`value)@&id=nm`nameID; $[#v; *v; ""]}
  family:    {[f] nameID[f;1]}
  subfamily: {[f] nameID[f;2]}
  fullName:  {[f] nameID[f;4]}
  / Single codepoint → glyph id via the cmap (0=.notdef when unmapped).
  glyph: {[f;cp] c: f`cmap; cps: c`cp; $[cp in cps; (c`gid) cps?cp; 0]}
  / A whole char string → glyph ids (no ligatures/kerning). Vectorized: `?` gives
  / #cps for an absent codepoint, indexing the appended .notdef gid 0.
  shape: {[f;s]c:f`cmap;((c`gid),0) @ (c`cp)?`i$s}

  / ── glyf outline flattening (quadratic Bézier → polylines) ─────────────────
  / glyf stores on/off-curve points; two consecutive off-curve points imply an
  / on-curve midpoint. These flatten to (x;y) point lists, in FONT UNITS.
  QN: 8                                                            / subdivision steps per quad segment
  fpMid:  {0.5*x+y}
  / Flatten one quad a(on)→b(ctrl)→c(on), vectorized over QN sample times.
  fpQuad: {[a;b;c]
    tt: (1.+!QN)%QN;
    u: 1.-tt;
    +(((u*u)*a 0)+((2.*u*tt)*b 0)+(tt*tt)*c 0; ((u*u)*a 1)+((2.*u*tt)*b 1)+(tt*tt)*c 1)
    }
  / fold step over ((x;y);on) entries. state = (out; cur; pend; hp).
  fpOn:   {[st;p] $[st 3; (st[0],fpQuad[st 1;st 2;p]; p; st 2; 0); (st[0],,p; p; st 2; 0)]}
  fpOff:  {[st;p] $[st 3; (st[0],fpQuad[st 1;st 2;fpMid[st 2;p]]; fpMid[st 2;p]; p; 1); (st 0; st 1; p; 1)]}
  fpStep: {[st;e] $[e 1; fpOn[st;e 0]; fpOff[st;e 0]]}
  fpClose:{[fin;start] $[fin 3; (fin 0),fpQuad[fin 1;fin 2;start]; fin 0]}
  fpStart:{[pts;on;hasOn] $[hasOn; pts on?1; fpMid[pts(-1+#pts); pts 0]]}
  fpSeq:  {[pr;on;hasOn] $[hasOn; 1 _ (((on?1) _ pr),((on?1)#pr)); pr]}
  fpFlatC:{[c]
    pts: c 0; on: c 1;
    pr: +(pts;on);
    hasOn: 1 in on;
    start: fpStart[pts;on;hasOn];
    seq: fpSeq[pr;on;hasOn]; fpClose[fpStep/[(,start; start; (0.;0.); 0); seq]; start]
  }
  / simple glyph dict → list of contours, each (pts;on); split with `_` cut.
  fpSC2:{[g]
    pts: +(0.+(g`x); 0.+(g`y));
    starts: 0,1+-1_(g`ends);
    +((starts _ pts); (starts _ g`on))
  }
  fpSimpleContours: {[g] $[0=#g`ends; (); fpSC2 g]}

  / ── composite glyphs + recursion ──────────────────────────────────────────
  / The face dict `f` (which holds the `glyf`/`CFF` lists) is threaded as a plain
  / argument, including through `'`-mapped projections — the old runtime bug that
  / forced a global here (a mapped projection capturing a heap array) is fixed.
  fpXform: {[xx;xy;yx;yy;dx;dy;c] xs: {x 0}'c; ys: {x 1}'c; +(((xx*xs)+(yx*ys)+dx); ((xy*xs)+(yy*ys)+dy))}
  fpCompRow:    {[f;r] xf: fpXform[r 3; r 4; r 5; r 6; r 1; r 2]; xf' GlyphC[f; r 0]}
  fpCompositeG: {[f;g] ps: g`parts; rows: +((ps`glyph); 0.+(ps`dx); 0.+(ps`dy); ps`xx; ps`xy; ps`yx; ps`yy); ,/ fpCompRow[f]'rows}
  / Resolved, flattened contours of a glyph in font units (composites recursed).
  GlyphC: {[f;gid]
    g: (f`glyf) gid;
    $[`parts in !g; fpCompositeG[f;g]; fpFlatC' fpSimpleContours g]
    }
  / Scale to pixels + flip y (font y-up → screen y-down) → flat F [x,y,x,y,...].
  fpEmit: {[sc;c] xs: {x 0}'c; ys: {x 1}'c; ,/ +((sc*xs); (-sc)*ys)}
  fpOutG: {[f;sc;gid] fpEmit[sc]' GlyphC[f;gid]}

  / ── CFF (PostScript) outlines — Type 2 charstrings interpreted in Zig ───────
  / Same shape as the glyf path. Local subrs: non-CID `localSubrs`, or per-FD
  / subrs picked by fdSelect (CID).
  cffLSubrs:{[c;gid]
    $[`localSubrs in !c; c`localSubrs; `fdLocalSubrs in !c; (c`fdLocalSubrs)@((c`fdSelect)gid); ()]
  }
  cffOutG:{[f;sc;gid]
    c: f`CFF; cffOutline0 ((c`charStrings)gid; c`globalSubrs; cffLSubrs[c;gid]; sc)
  }

  / ── public outline entry points ───────────────────────────────────────────
  / outline  f gid sz  → L of flat F contours (pixel-space, y-flipped). Feed each
  / contour to tessellate. outlines does the same for a whole gid vector at once.
  outline:  {[f;gid;sz] $[`CFF in !f; cffOutG[f;scale[f;sz];gid]; fpOutG[f;scale[f;sz];gid]]}
  outlines: {[f;sz;gids] $[`CFF in !f; cffOutG[f;scale[f;sz]]'gids; fpOutG[f;scale[f;sz]]'gids]}

\d

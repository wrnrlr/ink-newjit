/ lib/font.k — native sfnt font reader
/
/ Build first:  zig build font
/ Load with:    2: "lib/font.k"
/
/ ReadFont "path" → a LIST of face dicts (one per face; a TTC yields several,
/ a single TTF/OTF yields a one-element list — uniform API across flavours).
/
/ Each face dict is keyed by normalized table name → that table's normalized
/ value. Implemented so far:
/
/   head  maxp  hhea  hmtx  loca  post  name  OS2  cmap  cvt  fpgm  prep  gasp
/
/ Glyph flavour is `glyf` (TrueType outlines, with `loca`) vs `CFF`/`CFF2`
/ (PostScript outlines) — query glyphs per flavour. Only tables actually
/ present in the file appear in the dict.
/
/ Outline extraction and text shaping are rebuilt on top of this in a later
/ step (the old tatfi-backed FontShape/FontOutline/FontMetrics are retired).

so:"./zig-out/lib/libfont.dylib"
ReadFont:so 2:(`ReadFont;1)      / "path" → L of face dicts
cffOutline0:so 2:(`cffOutline;1) / (charstring_C; gsubrs_L; lsubrs_L; scale_f) → L of flat F contours (CFF outlines)

/ First string for a given nameID (1=family, 2=subfamily, 4=full, 6=postscript),
/ or "" if absent.  f: face dict.
FontNameID: {[f;id] nm: f`name; v: (nm`value)@&id=nm`nameID; $[#v; *v; ""]}
FontFamily:    {[f] FontNameID[f;1]}
FontSubfamily: {[f] FontNameID[f;2]}
FontFullName:  {[f] FontNameID[f;4]}

/ Codepoint → glyph id via the best Unicode cmap subtable (0 if unmapped).
/ f: face dict.  cp: int codepoint.
FontGlyph: {[f;cp] c: f`cmap; cps: c`cp; $[cp in cps; (c`gid) cps?cp; 0]}

/ Units per em (em-square size).
FontUpm: {[f] f[`head]`upm}

/ Em→pixel scale factor at a given pixel size.
FontScale: {[f;sz] sz % FontUpm f}

/ ── outline flattening (glyf TrueType outlines → polyline contours) ────────────
/
/ The glyf table stores quadratic Bézier outlines as on/off-curve points; two
/ consecutive off-curve points imply an on-curve midpoint between them. These
/ helpers turn that into flat polylines, resolve composite glyphs, and scale.
/
/ Points are (x;y) float pairs throughout. A contour is a list of points.

/ NOTE on style (both are real ink constraints, not preferences):
/  (1) Every $[...] is on ONE line — a multi-line $[] hangs the parser at load.
/  (2) NO projection captures a heap array (vector/list) that is then mapped with
/      `'` — that pattern hits a runtime bug (doc/bug.md #7). So contour points
/      are vectorized (whole-vector arithmetic), contours are split with `_`
/      cut, and `'`-mapped functions capture only SCALARS or DICTS.

QN: 8   / quadratic subdivision steps per off-curve segment

/ midpoint of two points
fpMid: {0.5*x+y}

/ Flatten one quadratic a(on)→b(ctrl)→c(on), VECTORIZED over the QN sample times:
/ B(t) = (1-t)²a + 2(1-t)t·b + t²c.  Returns inner points (excludes a, includes c).
fpQuad: {[a;b;c] tt: (1.+!QN)%QN; u: 1.-tt; +(((u*u)*a 0)+((2.*u*tt)*b 0)+(tt*tt)*c 0; ((u*u)*a 1)+((2.*u*tt)*b 1)+(tt*tt)*c 1)}

/ fold step over ((x;y);on) entries. state = (out; cur; pend; hp)
/   out=points so far, cur=last on-curve pt, pend=held control pt, hp=1 if pend valid
fpOn:  {[st;p] $[st 3; (st[0],fpQuad[st 1;st 2;p]; p; st 2; 0); (st[0],,p; p; st 2; 0)]}
fpOff: {[st;p] $[st 3; (st[0],fpQuad[st 1;st 2;fpMid[st 2;p]]; fpMid[st 2;p]; p; 1); (st 0; st 1; p; 1)]}
fpStep: {[st;e] $[e 1; fpOn[st;e 0]; fpOff[st;e 0]]}

/ close: append a final quad through the pending control back to start, if any
fpClose: {[fin;start] $[fin 3; (fin 0),fpQuad[fin 1;fin 2;start]; fin 0]}

/ flatten one contour c=(pts;on) → list of (x;y) points (font units)
fpStart: {[pts;on;hasOn] $[hasOn; pts on?1; fpMid[pts(-1+#pts); pts 0]]}
fpSeq:   {[pr;on;hasOn] $[hasOn; 1 _ (((on?1) _ pr),((on?1)#pr)); pr]}
fpFlatC: {[c] pts: c 0; on: c 1; pr: +(pts;on); hasOn: 1 in on; start: fpStart[pts;on;hasOn]; seq: fpSeq[pr;on;hasOn]; fpClose[fpStep/[(,start; start; (0.;0.); 0); seq]; start]}

/ simple glyph dict → list of contours, each (pts;on); split with `_` cut (no map)
fpSC2: {[g] pts: +(0.+(g`x); 0.+(g`y)); starts: 0,1+-1_(g`ends); +((starts _ pts); (starts _ g`on))}
fpSimpleContours: {[g] ends: g`ends; $[0=#ends; (); fpSC2 g]}

/ Resolved, flattened contours of a glyph in FONT UNITS (composites recursed).
/ f: face dict.  gid: glyph id.  → list of contours (each a list of (x;y) points)
/
/ The face dict is held in the global FpFont during extraction rather than
/ captured in a mapped projection: the dict contains `glyf` (a list), and
/ capturing a list-bearing value into a `'`-mapped projection hits the runtime
/ bug. The recursion worker GlyphC reads FpFont; only scalars/vector-dicts are
/ ever captured. fpXform transforms one contour by a component's 2×2 + offset.
FpFont: ()   / face dict in scope for the current outline extraction
fpXform: {[xx;xy;yx;yy;dx;dy;c] xs: {x 0}'c; ys: {x 1}'c; +(((xx*xs)+(yx*ys)+dx); ((xy*xs)+(yy*ys)+dy))}
/ Transpose the component columns into per-row scalar tuples so the mapped
/ function fpCompRow is a PLAIN lambda (captures nothing — no list/vector held
/ in a projection). row = (glyph; dx; dy; xx; xy; yx; yy).
fpCompRow: {[r] xf: fpXform[r 3; r 4; r 5; r 6; r 1; r 2]; xf' GlyphC r 0}
fpCompositeG: {[g] ps: g`parts; rows: +((ps`glyph); 0.+(ps`dx); 0.+(ps`dy); ps`xx; ps`xy; ps`yx; ps`yy); ,/ fpCompRow'rows}
GlyphC: {[gid] g: (FpFont`glyf) gid; $[`parts in !g; fpCompositeG g; fpFlatC' fpSimpleContours g]}
GlyphContours: {[f;gid] FpFont:: f; GlyphC gid}

/ Pixel-space outline for a glyph: scales to size and flips y (font y-up → screen
/ y-down). f: face.  gid: glyph id.  sz: pixel size.  → L of flat F [x,y,x,y,...]
/ Pass each contour to Tessellate (as the old API did).
fpEmit: {[sc;c] xs: {x 0}'c; ys: {x 1}'c; ,/ +((sc*xs); (-sc)*ys)}

/ CFF (PostScript) outlines — Type 2 charstrings interpreted in Zig. Returns the
/ same shape as the glyf path (L of flat F contours, pixel-scaled, y-flipped).
/ Local subrs: non-CID `localSubrs`, or per-FD subrs picked by fdSelect (CID).
cffLSubrs: {[c;gid] $[`localSubrs in !c; c`localSubrs; `fdLocalSubrs in !c; (c`fdLocalSubrs)@((c`fdSelect)gid); ()]}
cffOutG:   {[sc;gid] c: FpFont`CFF; cffOutline0 ((c`charStrings)gid; c`globalSubrs; cffLSubrs[c;gid]; sc)}
fpOutG:    {[sc;gid] fpEmit[sc]' GlyphC gid}

/ Pixel-space outline for a glyph: scales to size, flips y (font y-up → screen
/ y-down). Dispatches on glyph flavour (glyf vs CFF). f: face. gid: glyph id.
/ sz: pixel size. → L of flat F [x,y,x,y,...]. Pass each contour to Tessellate.
FontOutline: {[f;gid;sz] FpFont:: f; $[`CFF in !f; cffOutG[FontScale[f;sz];gid]; fpOutG[FontScale[f;sz];gid]]}

/ Outlines for MANY glyphs at once → list (per glyph) of L of flat F contours.
/ Use this to render a string: it threads the face dict via the FpFont global so
/ nothing captures the (list-bearing) face dict in a mapped projection (which
/ would hit the runtime bug). f: face. sz: px. gids: I glyph ids.
FontOutlines:{[f;sz;gids] FpFont::f; $[`CFF in !f; cffOutG[FontScale[f;sz]]'gids; fpOutG[FontScale[f;sz]]'gids]}

/ Map a char string to glyph ids via the cmap (no ligatures/kerning).
/ Vectorized: find every codepoint in the cmap at once (capturing the face dict
/ in a `'`-mapped projection would hit the runtime bug — it holds `glyf`).
FontShape: {[f;s] c: f`cmap; cps: c`cp; codes: `i$s; pos: cps?codes; (codes in cps)*(c`gid)@0|pos}

/ Pixel metrics at a size: (ascent; descent; lineGap) in pixels.
FontMetrics: {[f;sz] (FontScale[f;sz]) * f[`hhea]`ascent`descent`lineGap}

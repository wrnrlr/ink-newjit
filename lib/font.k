/   head  maxp  hhea  hmtx  loca  post  name  OS2  cmap  cvt  fpgm  prep  gasp
\d font read outline outlines shape scale metrics upm glyph nameID family subfamily fullName
  so: "./zig-out/lib/libfont.dylib"
  read:so 2:(`ReadFont;   1) / "path" → L of face dicts
  cff.outline: so 2:(`cffOutline; 1) / (charstring_C; gsubrs_L; lsubrs_L; scale_f) → L of flat F contours
  upm:{[f] f[`head]`upm}   / units per em (em-square)
  scale:{[f;sz] sz % upm f}  / em → pixel factor at size sz
  metrics:{[f;sz] (scale[f;sz]) * f[`hhea]`ascent`descent`lineGap}   / → (ascent; descent; lineGap) px
  nameID:{[f;id] nm: f`name; v: (nm`value)@&id=nm`nameID; $[#v; *v; ""]}
  family:{[f] nameID[f;1]}
  subfamily:{[f] nameID[f;2]}
  fullName:{[f] nameID[f;4]}
  / Single codepoint → glyph id via the cmap (0=.notdef when unmapped).
  glyph: {[f;cp] c: f`cmap; cps: c`cp; $[cp in cps; (c`gid) cps?cp; 0]}
  / A whole char string → glyph ids (no ligatures/kerning). Vectorized: `?` gives
  / #cps for an absent codepoint, indexing the appended .notdef gid 0.
  shape: {[f;s]c:f`cmap;((c`gid),0)@(c`cp)?`i$s}
  midway:{0.5*x+y}
  subdivide:{[a;b;c]
    QN:8;tt:(1.+!QN)%QN;
    u:1.-tt;u2:u*u;utt2:2.*u*tt;tt2:tt*tt
    +((u2*a 0)+(utt2*b 0)+tt2*c 0
      (u2*a 1)+(utt2*b 1)+tt2*c 1)
  }
  / fold step over ((x;y);on) entries. state = (out; cur; pend; hp).
  fpOn:{[st;p]
    $[st 3;(st[0],subdivide[st 1;st 2;p]; p; st 2; 0);
           (st[0],,p; p; st 2; 0)]
  }
  fpOff:{[st;p]
    $[st 3;(st[0],subdivide[st 1;st 2;midway[st 2;p]];midway[st 2;p]; p; 1); 
      (st 0; st 1; p; 1)]
  }
  fpStep:{[st;e] $[e 1; fpOn[st;e 0]; fpOff[st;e 0]]}
  fpStart:{[pts;on;hasOn] $[hasOn; pts on?1; midway[pts(-1+#pts); pts 0]]}
  fpSeq:{[pr;on;hasOn] $[hasOn; 1 _ (((on?1) _ pr),((on?1)#pr)); pr]}
  fpFlatC:{[c]
    pts:c 0;on:c 1;
    pr:+(pts;on);
    hasOn:1 in on;
    start:fpStart[pts;on;hasOn];
    seq:fpSeq[pr;on;hasOn];
    acc:(,start;start;(0.;0.);0)fpStep/seq
    $[acc 3; (acc 0),subdivide[acc 1;acc 2;start]; acc 0]
  }
  / simple glyph dict → list of contours, each (pts;on); split with `_` cut.
  fpSC2:{[g]
    pts:+(0.+(g`x); 0.+(g`y));
    starts:0,1+-1_(g`ends);
    +((starts_pts);(starts_g`on))
  }
  fpSimpleContours: {[g] $[0=#g`ends; (); fpSC2 g]}
  fpXform: {[xx;xy;yx;yy;dx;dy;c]
    xs: {x 0}'c;
    ys: {x 1}'c; +(((xx*xs)+(yx*ys)+dx); ((xy*xs)+(yy*ys)+dy))
  }
  fpCompRow:    {[f;r] xf: fpXform[r 3; r 4; r 5; r 6; r 1; r 2]; xf' GlyphC[f; r 0]}
  fpCompositeG: {[f;g]
    ps: g`parts;
    rows: +((ps`glyph); 0.+(ps`dx); 0.+(ps`dy); ps`xx; ps`xy; ps`yx; ps`yy);
    ,/ fpCompRow[f]'rows
  }
  GlyphC: {[f;gid]
    g: (f`glyf) gid;
    $[`parts in !g; fpCompositeG[f;g]; fpFlatC' fpSimpleContours g]
    }
  / Scale to pixels + flip y (font y-up → screen y-down) → flat F [x,y,x,y,...].
  fpEmit: {[sc;c] xs: {x 0}'c; ys: {x 1}'c; ,/ +((sc*xs); (-sc)*ys)}
  fpOutG: {[f;sc;gid] fpEmit[sc]' GlyphC[f;gid]}
  cffLSubrs:{[c;gid]
    $[`localSubrs in !c; c`localSubrs; `fdLocalSubrs in !c; (c`fdLocalSubrs)@((c`fdSelect)gid); ()]
  }
  cffOutG:{[f;sc;gid]
    c:f`CFF;
    cff.outline((c`charStrings)gid;c`globalSubrs;cffLSubrs[c;gid];sc)
  }
  outline:  {[f;gid;sz]
    $[`CFF in !f; cffOutG[f;scale[f;sz];gid]; fpOutG[f;scale[f;sz];gid]]}
  outlines:{[f;sz;gids]
    $[`CFF in !f; cffOutG[f;scale[f;sz]]'gids; fpOutG[f;scale[f;sz]]'gids]}

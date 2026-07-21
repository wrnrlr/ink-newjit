/ lib/canvas.k — a Canvas/Gio-style 2D recorder over an ops table (Phase 0).
/
/ Build first:  zig build gpu
/ Load with:    2: "lib/canvas.k"
/
/ WHAT THIS IS
/ ------------
/ An immediate-mode drawing API (moveTo/lineTo/quadTo/cubicTo/fill/stroke) that
/ RECORDS into a retained, columnar "ops table" instead of drawing eagerly. Every
/ path reduces to quadratic Béziers (lines = degenerate quads, cubics split to two
/ quads), which is exactly what the Slug analytic rasterizer consumes.
/
/ Each draw carries its own 2×3 affine transform (the CTM at fill/stroke time) —
/ points are stored in LOCAL space and the transform rides alongside. cnv.render bins
/ every draw's curves + paint into ONE resident scene buffer and issues one bbox-quad
/ pull draw each (recursively — draws inside '/ / adverbs are eliminated, so a dynamic
/ draw count needs recursion).
/
/ THE OPS TABLE (cnv.scene[])
/ ---------------------------
/   draws  — one row per fill/stroke: kind(0 fill,1 stroke) pidx width rule
/            cstart ccount constart concount  (CSR indices, in segments/contours)
/   curves — flat F, 6 per quadratic segment [x0 y0 cx cy x1 y1] (local space)
/   conlen — flat I, quadratic-segment count per contour
/   xf     — flat F, 6 per draw (the 2×3 affine [a b c d e f])
/   paints — list of 44-float fragment-uniform blocks (gpu.solid / gradients)
/ Draw i owns curves[cstart..cstart+ccount] and contours conlen[constart..+concount].
/
/ USAGE (globals-as-state, like the ECS `wld` or edit.k's RowGids)
/ ----------------------------------------------------------------
/   run:{[props]
/     cnv.new[]
/     cnv.save[]; cnv.translate[100.;100.]; cnv.rotate[props`time]
/     cnv.moveTo[0.;-40.]; cnv.lineTo[40.;40.]; cnv.lineTo[-40.;40.]; cnv.close[]
/     cnv.fill cnv.rgba[0.9;0.3;0.2;1.]
/     cnv.restore[]
/     cnv.render[props`width; props`height] }   / w,h = framebuffer size (for Slug text)
/   window.run[run; 640. 480.]
/
/ EVERYTHING — solid/gradient fills, clips, strokes, and text — renders through the ONE
/ analytic Slug SCENE-BUFFER backend (lib/slug.k): resolution-independent, antialiased,
/ one resident curve buffer per frame, the paint (gradient/solid + scissor clip) evaluated
/ per pixel in the fragment. No tessellation. Strokes become fill outlines (miter joins).

2: "lib/gpu.k"
2: "lib/slug.k"

\d cnv new save restore translate scale rotate xform moveTo lineTo quadTo cubicTo close text fill stroke rgba linearGradient radialGradient boxGradient clip noClip render scene draws ndraws

  / ── State (private members; initialised here so bare names resolve to cnv.*) ──
  CTM:  1. 0. 0. 1. 0. 0.   / current transform [a b c d e f]: (x,y)→(a x+c y+e, b x+d y+f)
  STK:  ()                  / save/restore stack of (CTM;CLIPM;CLIPE) tuples
  PEN:  0. 0.               / current point (path building)
  SUB0: 0. 0.               / current subpath start
  CUR:  0#0.                / accumulating quad buffer of the current subpath (6/seg)
  PATH: ()                  / completed contour buffers of the pending path
  CLIPM: 1. 0. 0. 1. 0. 0.  / scissor matrix (screen→clip-local); identity = no clip
  CLIPE: 1e10 1e10 1. 1.    / scissorExt.xy + scissorScale.zw; huge ext = no clip

  / ── Ops table columns ──
  KIND:0#0; PIDX:0#0; WIDTH:0#0.; RULE:0#0
  CSTART:0#0; CCOUNT:0#0; CONSTART:0#0; CONCOUNT:0#0
  XF:0#0.; CURVES:0#0.; CONLEN:0#0; PAINTS:()

  / ── Lifecycle ────────────────────────────────────────────────────────────────
  new:{[] CTM::1. 0. 0. 1. 0. 0.; STK::(); PEN::0. 0.; SUB0::0. 0.; CUR::0#0.; PATH::()
    CLIPM::1. 0. 0. 1. 0. 0.; CLIPE::1e10 1e10 1. 1.
    KIND::0#0; PIDX::0#0; WIDTH::0#0.; RULE::0#0
    CSTART::0#0; CCOUNT::0#0; CONSTART::0#0; CONCOUNT::0#0
    XF::0#0.; CURVES::0#0.; CONLEN::0#0; PAINTS::()
    TXFACE::(); TXGID::0#0; TXPX::0#0.; TXPY::0#0.; TXSZ::0#0.; TXCOL::(); TXXF::()}

  / ── Affine transform ─────────────────────────────────────────────────────────
  / compose m∘n: the matrix that applies n first, then m (post-multiply for nesting).
  mul:{[m;n]
    A:((m 0)*(n 0))+((m 2)*(n 1))
    B:((m 1)*(n 0))+((m 3)*(n 1))
    C:((m 0)*(n 2))+((m 2)*(n 3))
    D:((m 1)*(n 2))+((m 3)*(n 3))
    E:(((m 0)*(n 4))+((m 2)*(n 5)))+(m 4)
    G:(((m 1)*(n 4))+((m 3)*(n 5)))+(m 5)
    A,B,C,D,E,G}
  / Inverse of a 2×3 affine [a b c d e f].
  invAffine:{[m]
    a:m 0; b:m 1; c:m 2; d:m 3; e:m 4; f:m 5
    id:1.%((a*d)-(c*b))
    A:d*id; B:(-b)*id; C:(-c)*id; D:a*id
    A,B,C,D,((-1.)*((A*e)+(C*f))),((-1.)*((B*e)+(D*f)))}
  save:{[] STK::STK,(,(CTM;CLIPM;CLIPE))}
  restore:{[] s:*|STK; CTM::s 0; CLIPM::s 1; CLIPE::s 2; STK::-1_STK}
  translate:{[x;y] CTM::mul[CTM; 1.,0.,0.,1.,x,y]}
  scale:{[sx;sy] CTM::mul[CTM; sx,0.,0.,sy,0.,0.]}
  rotate:{[th] c:cos th; s:sin th; CTM::mul[CTM; c,s,(-s),c,0.,0.]}
  xform:{[m] CTM::mul[CTM;m]}

  / ── Path building (local coordinates; a quad seg = [x0 y0 cx cy x1 y1]) ───────
  doFlush:{[] PATH::PATH,(,CUR); CUR::0#0.}
  flushSub:{[] $[0<#CUR; doFlush[]; 0]}
  appendSeg:{[seg] CUR::CUR,seg}
  moveTo:{[x;y] flushSub[]; PEN::x,y; SUB0::x,y}
  lineTo:{[x;y] appendSeg[,/(PEN; 0.5*PEN+x,y; x,y)]; PEN::x,y}
  quadTo:{[cx;cy;x;y] appendSeg[(PEN 0),(PEN 1),cx,cy,x,y]; PEN::x,y}
  / cubic P0(pen)C1 C2 P3 → two quadratics via one de Casteljau split at t=0.5.
  cubicTo:{[c1x;c1y;c2x;c2y;x;y]
    P0:PEN; C1:c1x,c1y; C2:c2x,c2y; P3:x,y
    a:0.5*P0+C1; b:0.5*C1+C2; e:0.5*C2+P3
    d:0.5*a+b; g:0.5*b+e; m:0.5*d+g
    ql:0.25*((3.*a+d)-(P0+m))
    qr:0.25*((3.*g+e)-(m+P3))
    appendSeg[,/(P0;ql;m)]; appendSeg[,/(m;qr;P3)]; PEN::P3}
  doClose:{[] appendSeg[,/(PEN; 0.5*PEN+SUB0; SUB0)]; flushSub[]; PEN::SUB0}
  close:{[] $[0<#CUR; doClose[]; 0]}

  / ── Text (analytic Slug coverage — resolution-independent, antialiased) ──────
  / cnv.text[face; sz; str; paint] lays str's glyphs left-to-right from the current
  / pen (its baseline-left origin, e.g. set with moveTo) at pixel size sz, coloured by
  / paint's inner colour. Glyphs are RECORDED here and rendered by cnv.render through
  / lib/slug.k's SCENE-BUFFER path (same as the solid fills): each glyph's raw quadratic
  / outline bins into the frame's shared curve buffer and draws as a bbox quad with
  / per-pixel Bézier coverage + AA. No kerning/ligatures.
  TXFACE: ()     / per-glyph face
  TXGID:  0#0    / per-glyph glyph id
  TXPX:   0#0.   / per-glyph pen x (local)
  TXPY:   0#0.   / per-glyph pen y (local baseline)
  TXSZ:   0#0.   / per-glyph pixel size
  TXCOL:  ()     / per-glyph rgba
  TXXF:   ()     / per-glyph transform (2×3)
  slugText:{[face;sz;gids;paint]
    n:#gids; sc:font.scale[face;sz]; adv:(face`hmtx)`adv; na:#adv
    advPx: sc*adv@(gids & na-1)
    ox:PEN 0; oy:PEN 1
    penXs: ox+0.,+\-1_advPx
    rgba: 4#24_paint                              / paint's inner colour (frag[6])
    TXFACE::TXFACE,(n#,face); TXGID::TXGID,gids
    TXPX::TXPX,penXs; TXPY::TXPY,n#oy; TXSZ::TXSZ,n#sz
    TXCOL::TXCOL,(n#,rgba); TXXF::TXXF,(n#,CTM)
    PEN::(ox++/advPx),oy}
  / 1_0,… normalises a single-char string (a char ATOM) to a 1-glyph vector.
  text:{[face;sz;s;paint] g:1_0,font.shape[face;s]; $[0<#g; slugText[face;sz;g;paint]; 0]}

  / ── Paints (fill the built-in NanoVG uber-shader's 44-float FragUniforms) ─────
  / A 2×3 affine → the shader's mat3 (3 vec4, .xyz used, homogeneous last column).
  matCols:{[t] ((t 0),(t 1),0.,0.),((t 2),(t 3),0.,0.),((t 4),(t 5),1.,0.)}
  rgba:{[r;g;b;a] gpu.solid[r;g;b;a]}   / solid-colour paint block
  / Gradient paint: paintMat = inverse(CTM ∘ gradXform) maps screen fpos → the
  / paint-local space where a rounded-rect SDF (extent/rad/feather) drives the
  / inner→outer colour mix. Coords are in the CURRENT transform space (like paths).
  mkGrad:{[gx; inner; outer; extw; exth; rad; feather]
    pm:invAffine mul[CTM; gx]
    ,/((1. 0. 0. 0. 0. 1. 0. 0. 0. 0. 1. 0.); matCols pm; inner; outer; 1e10 1e10 1. 1.; extw,exth,rad,feather; 0. 0. 0. 0.)}
  / Linear gradient from (sx,sy) to (ex,ey). inner/outer are rgba 4-vectors.
  linearGradient:{[sx;sy;ex;ey;inner;outer]
    lg:1e5; dx:ex-sx; dy:ey-sy; d:sqrt[(dx*dx)+(dy*dy)]
    ux:$[d>1e-4; dx%d; 0.]; uy:$[d>1e-4; dy%d; 1.]
    gx:uy,(-ux),ux,uy,(sx-ux*lg),(sy-uy*lg)
    mkGrad[gx; inner; outer; lg; lg+0.5*d; 0.; 1.|d]}
  / Radial gradient centred at (cx,cy), colour inner at radius inr → outer at outr.
  radialGradient:{[cx;cy;inr;outr;inner;outer]
    r:0.5*inr+outr; f:outr-inr
    mkGrad[1.,0.,0.,1.,cx,cy; inner; outer; r; r; r; 1.|f]}
  / Box gradient: a feathered/rounded rect (x,y,w,h; corner rad; feather f).
  boxGradient:{[x;y;w;h;rad;f;inner;outer]
    mkGrad[1.,0.,0.,1.,(x+0.5*w),(y+0.5*h); inner; outer; 0.5*w; 0.5*h; rad; 1.|f]}
  / Clip subsequent draws to rect (x,y,w,h) in the current transform space. Scoped
  / by save/restore (REPLACES, does not intersect). Reset early with cnv.noClip.
  clip:{[x;y;w;h]
    c2s:mul[CTM; 1.,0.,0.,1.,(x+0.5*w),(y+0.5*h)]
    CLIPM::invAffine c2s
    CLIPE::(0.5*w),(0.5*h),sqrt[((CTM 0)*(CTM 0))+((CTM 1)*(CTM 1))],sqrt[((CTM 2)*(CTM 2))+((CTM 3)*(CTM 3))]}
  noClip:{[] CLIPM::1. 0. 0. 1. 0. 0.; CLIPE::1e10 1e10 1. 1.}
  / Bake the active clip (scissorMat @ frag[0..2], scissorExt/scale @ frag[8]) into
  / a paint at register time, then store it. No clip ⇒ identity/huge ⇒ no-op.
  applyClip:{[p] @[@[p; !12; :; matCols CLIPM]; 32+!4; :; CLIPE]}
  regPaint:{[p] i:#PAINTS; PAINTS::PAINTS,(,applyClip p); i}

  / ── Emit a draw (flush pending path into the ops table) ───────────────────────
  doEmit:{[kind;paint;width;rule]
    pid:regPaint paint
    clens:{(#x)div 6}'PATH
    cs:(#CURVES)div 6
    cns:#CONLEN
    CURVES::CURVES,(,/PATH)
    CONLEN::CONLEN,clens
    KIND::KIND,kind; PIDX::PIDX,pid; WIDTH::WIDTH,width; RULE::RULE,rule
    XF::XF,CTM
    CSTART::CSTART,cs; CCOUNT::CCOUNT,+/clens; CONSTART::CONSTART,cns; CONCOUNT::CONCOUNT,#PATH
    PATH::(); CUR::0#0.}
  emitDraw:{[kind;paint;width;rule] flushSub[]; $[0<#PATH; doEmit[kind;paint;width;rule]; 0]}
  fill:{[paint] emitDraw[0; paint; 0.; 0]}
  stroke:{[paint;width] emitDraw[1; paint; width; 0]}

  / ── Ops-table introspection (feeds a GPU backend later) ───────────────────────
  ndraws:{[] #KIND}
  draws:{[] +(`kind`pidx`width`rule`cstart`ccount`constart`concount)!(KIND;PIDX;WIDTH;RULE;CSTART;CCOUNT;CONSTART;CONCOUNT)}
  scene:{[] `draws`curves`conlen`xf`paints!(draws[];CURVES;CONLEN;XF;PAINTS)}

  / ── Ops-table geometry accessors (feed the Slug scene buffer) ────────────────
  drawM:{[i] XF@(6*i)+!6}
  / Draw i's contour buffers (list of flat quad buffers), local space.
  drawContours:{[i]
    cc:CCOUNT i; cs:CSTART i; ncon:CONCOUNT i; cns:CONSTART i
    dbuf:(6*cc)#(6*cs)_CURVES
    clens:CONLEN@cns+!ncon
    (6*(0,+\-1_clens))_dbuf}
  / Transform a flat [x y x y …] buffer by the 2×3 affine m.
  xfBuf:{[m;buf]
    hp:(#buf)div 2; ix:2*!hp; xs:buf ix; ys:buf@ix+1
    X:(((m 0)*xs)+((m 2)*ys))+(m 4)
    Y:(((m 1)*xs)+((m 3)*ys))+(m 5)
    ,/+(X;Y)}
  / Flatten one quadratic seg [x0 y0 cx cy x1 y1] to QN sample points (t=1/QN..1) — used
  / by the stroke path to turn curved segments into a polyline before offsetting.
  segPts:{[seg]
    QN:16; tt:(1.+!QN)%QN; u:1.-tt; uu:u*u; ut:2.*u*tt; t2:tt*tt
    X:((uu*(seg 0))+(ut*(seg 2)))+(t2*(seg 4))
    Y:((uu*(seg 1))+(ut*(seg 3)))+(t2*(seg 5))
    ,/+(X;Y)}
  / ── Stroke → fill outline (SCREEN space) ─────────────────────────────────────
  / A stroke becomes a FILL: ONE closed outline that offsets every vertex by ±half-width
  / along its MITER normal (the bisector of the two adjacent segment normals). One contour
  / of ~2·npts edges — far cheaper than per-segment rects + join discs (those pile many
  / curves into the vertex bands and truncate at slugMPB). Butt caps at the open ends.
  / Nonzero winding fills it (self-intersections at sharp corners stay filled). Fed to the
  / Slug scene buffer like any fill → strokes get the same coverage + paint/gradient/clip.
  / Closed polygon [x y …] → a flat quadratic contour (one degenerate quad per edge,
  / control = edge midpoint), wrapping last→first.
  polyContour:{[fp]
    n:(#fp)div 2; i:!n; j:(1+i)mod n
    xs:fp@2*i; ys:fp@1+2*i; nx:fp@2*j; ny:fp@1+2*j
    ,/+(xs; ys; 0.5*xs+nx; 0.5*ys+ny; nx; ny)}
  / Miter outline of an OPEN screen polyline (np points) at half-width hw → ONE ribbon
  / contour: left offsets forward then right offsets reversed (a strip with butt caps at
  / the ends — their vertex normal is just the adjacent segment normal; interior miters).
  miterOpen:{[pts;np;hw]
    xs:pts@2*!np; ys:pts@1+2*!np
    sx:(1_xs)-(-1_xs); sy:(1_ys)-(-1_ys)
    L:1e-6|sqrt[(sx*sx)+(sy*sy)]; nx:(0.-sy)%L; ny:sx%L          / np-1 segment normals
    vnx:(*nx),((-1_nx)+(1_nx)),(*|nx); vny:(*ny),((-1_ny)+(1_ny)),(*|ny)
    vl:1e-6|sqrt[(vnx*vnx)+(vny*vny)]; mx:vnx%vl; my:vny%vl
    ri:(!np)&(np-2)
    sca:hw%(0.25|((mx*nx@ri)+(my*ny@ri)))
    ,polyContour[,/+(((xs+sca*mx),|(xs-sca*mx)); ((ys+sca*my),|(ys-sca*my)))]}
  / Miter outline of a CLOSED polyline (from cnv.close: last point ≈ first). Drop the
  / duplicate vertex, wrap the segments, miter EVERY vertex. A closed stroke is an ANNULUS,
  / so return TWO contours — outer (left offset) + inner (right offset, REVERSED so its
  / winding opposes the outer): nonzero winding then fills the ring and empties the hole.
  miterClosed:{[pts;np;hw]
    nv:np-1; i:!nv; j:(1+i)mod nv
    xs:nv#pts@2*!np; ys:nv#pts@1+2*!np
    sdx:(xs@j)-xs; sdy:(ys@j)-ys
    L:1e-6|sqrt[(sdx*sdx)+(sdy*sdy)]; nx:(0.-sdy)%L; ny:sdx%L    / nv segment normals
    pi:(i+nv-1)mod nv                                            / previous segment index
    vnx:(nx@pi)+nx; vny:(ny@pi)+ny
    vl:1e-6|sqrt[(vnx*vnx)+(vny*vny)]; mx:vnx%vl; my:vny%vl
    sca:hw%(0.25|((mx*nx)+(my*ny)))
    (polyContour[,/+((xs+sca*mx); (ys+sca*my))]; polyContour[,/+(|(xs-sca*mx); |(ys-sca*my))])}
  / A path whose last point ≈ first is CLOSED — annulus (2 contours); else a ribbon (1).
  miterContour:{[pts;np;hw]
    xs:pts@2*!np; ys:pts@1+2*!np
    $[(1e-4>abs[(*xs)-(*|xs)]) & (1e-4>abs[(*ys)-(*|ys)]); miterClosed[pts;np;hw]; miterOpen[pts;np;hw]]}
  / strokeOutline[pts;hw] → list of outline contours (empty if <2 points).
  strokeOutline:{[pts;hw] np:(#pts)div 2; $[np<2; (); miterContour[pts;np;hw]]}
  / ── Shared corner math ──────────────────────────────────────────────────────
  / The Slug fragment needs the SCREEN pos (for the paint/scissor matrices) AND the clip
  / pos (for gl_Position), so every draw hands slug.fillDraw both sets of 4 corners.
  SFW: 0.; SFH: 0.
  toScreen:{[m;lx;ly] (((m 0)*lx)+((m 2)*ly)+(m 4)) , (((m 1)*lx)+((m 3)*ly)+(m 5))}
  scrClip:{[s] (((2.*(s 0))%SFW)-1.) , (1.-((2.*(s 1))%SFH))}
  / drawQuad[off;cl;m;ox;oy] — draw one scene-buffer fill: uv-rect cl offset by (ox,oy) in
  / local space, transformed by m → 4 SCREEN + 4 clip corners; per-draw AA ≈1.2 screen px.
  drawQuad:{[off;cl;m;ox;oy]
    sa:toScreen[m; ox+cl 0; oy+cl 3]; sb:toScreen[m; ox+cl 2; oy+cl 3]
    sc:toScreen[m; ox+cl 2; oy+cl 1]; sd:toScreen[m; ox+cl 0; oy+cl 1]
    ca:scrClip sa; cb:scrClip sb; cc:scrClip sc; cd:scrClip sd
    e:cb-ca; cw:1e-6|sqrt[((e 0)*(e 0))+((e 1)*(e 1))]
    slug.fillDraw[(ca;cb;cc;cd); (sa;sb;sc;sd); off; 2.4%(cw*SFW)]}

  / ── Slug text pass — glyphs ride the SAME scene buffer as fills/strokes ─────────
  / Each glyph's raw quadratic outline (font.quads) is just another fill (a SOLID paint of
  / the glyph colour): addGlyph bins it during the accumulate phase, drawGlyphS draws its
  / bbox quad, the fragment reads the curves back for analytic coverage + holes + AA.
  / Coverage quads are SQUARES (aspect-preserving normalise) that overlap when packed, so
  / correct text needed the pull pipeline's depth relaxed to LESS_OR_EQUAL (see vk.zig).
  TXOFF:  0#0.   / per-glyph scene-buffer offset (-1 = empty glyph, e.g. space: skip)
  TXRECT: ()     / per-glyph uv-square rect in glyph pixel space (from addFill)
  / A space/empty glyph has no contours — addFill would bin garbage (min/max over an empty
  / point set) and poison the shared buffer; record a -1 sentinel and skip its draw. NB:
  / the skip branch is a NAMED helper, not an inline [..;..] block — a bracket block in a
  / $[...] branch parses as a DICT literal (runs nothing), which would desync TXOFF/TXRECT.
  txPaint:{[i] c:TXCOL i; gpu.solid[c 0; c 1; c 2; c 3]}   / glyph = a solid-colour fill
  addGlyph:{[i]
    cs: font.quads[TXFACE i; TXGID i; TXSZ i]
    $[0<#cs; addGlyphC[i;cs]; addGlyphSkip[]]}
  addGlyphC:{[i;cs] r:slug.addFill[cs; 0.14; txPaint i]; TXOFF::TXOFF,r 0; TXRECT::TXRECT,,r 1}
  addGlyphSkip:{[] TXOFF::TXOFF,-1.; TXRECT::TXRECT,,0. 0. 0. 0.}
  scanTStep:{[i] addGlyph i; scanText i+1}
  scanText:{[i] $[i<#TXGID; scanTStep i; 0]}
  drawGlyphS:{[i] drawQuad[TXOFF i; TXRECT i; TXXF i; TXPX i; TXPY i]}
  drawTStep:{[i] $[(TXOFF i)<0.; 0; drawGlyphS i]; drawText i+1}
  drawText:{[i] $[i<#TXGID; drawTStep i; 0]}

  / ── Unified scene-buffer draw pass (fills + strokes, in ops-table order) ────────
  / EVERY fill/stroke bins its curves + 44-float paint block into the ONE scene buffer; the
  / fragment reads the curves for coverage AND evaluates the paint (gradient/solid + baked
  / clip) at its screen pos. No tessellation. Fills = local contours + drawM; strokes = a
  / SCREEN-space offset outline (so width is screen px) + identity transform.
  DOFF: 0#0.; DRECT: (); DXF: ()
  / Flatten a stroke contour to a polyline, but DON'T subdivide straight segments (control
  / ≈ midpoint) — a subdivided straight edge piles all its collinear pieces into ONE band
  / (a horizontal edge → 16 pieces × 2 outline sides > slugMPB → truncated/dropped). Curves
  / still get segPts. So a rectangle/zigzag stroke is just its corner points; curves stay smooth.
  segFlat:{[seg]
    mx:0.5*(seg 0)+(seg 4); my:0.5*(seg 1)+(seg 5)
    $[(1e-3>abs[(seg 2)-mx]) & (1e-3>abs[(seg 3)-my]); (seg 4),(seg 5); segPts seg]}
  strokeFlat:{[buf] nseg:(#buf)div 6; (2#buf),(,/segFlat'(6*!nseg)_buf)}
  strokeCs:{[i]
    m:drawM i; hw:0.5*WIDTH i
    polys:{strokeFlat x}'(m xfBuf/:drawContours i)
    ,/strokeOutline'[polys; (#polys)#hw]}
  drawCs:{[i] $[0=KIND i; drawContours i; strokeCs i]}
  drawXf:{[i] $[0=KIND i; drawM i; 1. 0. 0. 1. 0. 0.]}
  addDraw:{[i]
    r: slug.addFill[drawCs i; 0.14; PAINTS PIDX i]
    DOFF::DOFF,r 0; DRECT::DRECT,,r 1; DXF::DXF,,drawXf i}
  scanStep:{[i] addDraw i; scanDraws i+1}
  scanDraws:{[i] $[i<ndraws[]; scanStep i; 0]}
  drawOne:{[k] drawQuad[DOFF k; DRECT k; DXF k; 0.; 0.]}
  drawStep:{[k] drawOne k; drawFrom k+1}
  drawFrom:{[k] $[k<#DOFF; drawStep k; 0]}
  / render[w;h] — fills + strokes + text, ALL analytic through the ONE Slug scene buffer:
  / accumulate every draw's curves+paint → upload once → draw (fills/strokes in ops order,
  / then text on top). w,h = framebuffer size (= the fragment's screen space for paints).
  render:{[w;h]
    DOFF::0#0.; DRECT::(); DXF::(); TXOFF::0#0.; TXRECT::(); SFW::w; SFH::h
    slug.sceneBegin[]
    $[0<ndraws[]; scanDraws 0; 0]
    $[0<#TXGID; scanText 0; 0]
    $[(0<#DOFF)|(0<#TXGID); slug.sceneFlush[]; 0]
    $[0<#DOFF; drawFrom 0; 0]
    $[0<#TXGID; drawText 0; 0]}
\d

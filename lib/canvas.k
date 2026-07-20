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
/ quads) so the same encoding feeds both today's tessellate+fill backend and a
/ future GPU Slug rasterizer.
/
/ Each draw carries its own 2×3 affine transform (the CTM at fill/stroke time) —
/ points are stored in LOCAL space and the transform rides alongside, so a GPU
/ backend can transform on-device. cnv.render (Phase 0) applies the CTM on the CPU,
/ flattens the quads, and issues one gpu.fill per draw (recursively — draws inside
/ '/ / adverbs are eliminated, so a dynamic draw count needs recursion).
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
/ Fills/strokes/gradients rasterise on the CPU tessellate + NanoVG fill path; TEXT
/ (cnv.text) renders through the analytic Slug backend (lib/slug.k) — resolution-
/ independent, antialiased, composited over the fills.

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
  / lib/slug.k: each glyph is a cached curve texture drawn as a quad (positioned by the
  / current transform), with per-pixel Bézier coverage + AA. No kerning/ligatures.
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

  / ── CPU backend: reconstruct → transform → flatten → gpu.fill (Phase 0) ───────
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
  / Flatten one quadratic seg [x0 y0 cx cy x1 y1] to QN sample points (t=1/QN..1).
  segPts:{[seg]
    QN:16; tt:(1.+!QN)%QN; u:1.-tt; uu:u*u; ut:2.*u*tt; t2:tt*tt
    X:((uu*(seg 0))+(ut*(seg 2)))+(t2*(seg 4))
    Y:((uu*(seg 1))+(ut*(seg 3)))+(t2*(seg 5))
    ,/+(X;Y)}
  / Flatten a contour buffer (6/seg) to a polyline [x y x y …].
  flatContour:{[buf]
    nseg:(#buf)div 6
    segs:(6*!nseg)_buf
    (2#buf),(,/{segPts x}'segs)}
  / Fill: transform contours, flatten, NaN-separate (holes), tessellate, draw.
  fillDraw:{[i]
    m:drawM i
    polys:{flatContour x}'(m xfBuf/:drawContours i)
    gpu.fill[gpu.tessellate[,/{x,0n,0n}'polys]; PAINTS PIDX i]}
  / One stroke segment (A→B, half-width via normal) → 6 tri verts [x y u v].
  / v(=ftcoord.y) MUST be 1: the built-in fill shader multiplies alpha by
  / clamp(ftcoord.y,0,1) (its edge-AA fringe), so v=0 verts draw fully transparent.
  segQuad:{[ax;ay;bx;by;hw]
    dx:bx-ax; dy:by-ay; L:1e-6|sqrt[(dx*dx)+(dy*dy)]
    nx:((-dy)*hw)%L; ny:(dx*hw)%L
    p1:(ax+nx),(ay+ny); p2:(bx+nx),(by+ny); p3:(bx-nx),(by-ny); p4:(ax-nx),(ay-ny)
    ,/[(p1;p2;p3;p1;p3;p4),\:0. 1.]}
  / Stroke a polyline [x y …] with width w → tri verts (butt caps, no joins).
  strokePoly:{[w;pts]
    np:(#pts)div 2
    $[np<2; 0#0.; strokeSegs[w;pts;np]]}
  strokeSegs:{[w;pts;np]
    k:!np-1; ax:pts@2*k; ay:pts@(2*k)+1; bx:pts@2*k+1; by:pts@(2*k+1)+1
    ,/[segQuad'[ax;ay;bx;by;(#k)#0.5*w]]}
  strokeDraw:{[i]
    m:drawM i; w:WIDTH i
    polys:{flatContour x}'(m xfBuf/:drawContours i)
    v:,/[w strokePoly/:polys]
    $[0<#v; gpu.fill[v; PAINTS PIDX i]; 0]}
  drawIdx:{[i] $[0=KIND i; fillDraw i; strokeDraw i]}
  recStep:{[i] drawIdx i; recFrom i+1}
  recFrom:{[i] $[i<ndraws[]; recStep i; 0]}
  / ── Slug text pass (after the fills/strokes) ──────────────────────────────────
  / w,h = the framebuffer size (props`width/`height) — used as the Slug viewSize so
  / analytic text lands in the same pixel space as gpu.fill (which uses framebuffer).
  xf2:{[m;x;y] (((m 0)*x)+((m 2)*y)+(m 4)) , (((m 1)*x)+((m 3)*y)+(m 5))}
  drawGlyph:{[i]
    face:TXFACE i; gid:TXGID i; px:TXPX i; py:TXPY i; m:TXXF i
    cl: slug.cell[face; gid; TXSZ i]
    a: xf2[m; px+cl 0; py+cl 3]; b: xf2[m; px+cl 2; py+cl 3]
    c: xf2[m; px+cl 2; py+cl 1]; d: xf2[m; px+cl 0; py+cl 1]
    slug.drawCell[a; b; c; d; TXCOL i; ,slug.tex[face;gid]]}
  txStep:{[i] drawGlyph i; txFrom i+1}
  txFrom:{[i] $[i<#TXGID; txStep i; 0]}
  renderText:{[w;h] slug.begin[w;h]; txFrom 0}
  / render[w;h] — issue fills/strokes, then the Slug text pass. Pass the framebuffer
  / size (props`width/`height). (render[] with no size skips text.)
  render:{[w;h] $[0<ndraws[]; recFrom 0; 0]; $[0<#TXGID; renderText[w;h]; 0]}
\d

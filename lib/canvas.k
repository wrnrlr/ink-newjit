/
# canvas

A retained 2D drawing surface: record shapes into an ops table, then replay them.

## What this is
An immediate-mode drawing API (moveTo/lineTo/quadTo/cubicTo/fill/stroke) that
RECORDS into a retained, columnar "ops table" instead of drawing eagerly. Every
path reduces to quadratic Béziers (lines = degenerate quads, cubics split to two
quads), which is exactly what the Slug analytic rasterizer consumes.

Each draw carries its own 2×3 affine transform (the CTM at fill/stroke time) —
points are stored in LOCAL space and the transform rides alongside. cnv.render bins
every draw's curves + paint into ONE resident scene buffer and issues one bbox-quad
pull draw each (recursively — draws inside '/ / adverbs are eliminated, so a dynamic
draw count needs recursion).

## THE OPS TABLE (cnv.scene[])
  draws  — one row per fill/stroke: kind(0 fill,1 stroke) pidx width rule
           cstart ccount constart concount  (CSR indices, in segments/contours)
  curves — flat F, 6 per quadratic segment [x0 y0 cx cy x1 y1] (local space)
  conlen — flat I, quadratic-segment count per contour
  xf     — flat F, 6 per draw (the 2×3 affine [a b c d e f])
  paints — list of 44-float fragment-uniform blocks (gpu.solid / gradients)
Draw i owns curves[cstart..cstart+ccount] and contours conlen[constart..+concount].

## USAGE (globals-as-state, like the ECS `wld` or edit.k's RowGids)
  run:{[props]
    cnv.new[]
    cnv.save[]; cnv.translate[100.;100.]; cnv.rotate[props`time]
    cnv.moveTo[0.;-40.]; cnv.lineTo[40.;40.]; cnv.lineTo[-40.;40.]; cnv.close[]
    cnv.fill cnv.rgba[0.9;0.3;0.2;1.]
    cnv.restore[]
    cnv.render[props`width; props`height] }   / w,h = framebuffer size (for Slug text)
  window.run[run; 640. 480.]

EVERYTHING — solid/gradient fills, clips, strokes, and text — renders through the ONE
analytic Slug SCENE-BUFFER backend (lib/slug.k): resolution-independent, antialiased,
one resident curve buffer per frame, the paint (gradient/solid + scissor clip) evaluated
per pixel in the fragment. No tessellation. Strokes become fill outlines (miter joins).

Pure k — loads on the first reference to any `canvas.*` name.
\

2: "lib/gpu.k"
2: "lib/slug.k"

\d cnv new save restore translate scale rotate xform moveTo lineTo quadTo cubicTo close rect ellipse circle text fill stroke rgba linearGradient radialGradient boxGradient loadImg image clip noClip render scene draws ndraws

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
    TXGID::0#0; TXKEY::0#0; TXPB::(); TXPX::0#0.; TXPY::0#0.; TXXF::()
    gcSweep[]}

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
  flushSub:{[] $[0<#CUR; [PATH::PATH,(,CUR); CUR::0#0.]; 0]}
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
  close:{[] $[0<#CUR; [appendSeg[,/(PEN; 0.5*PEN+SUB0; SUB0)]; flushSub[]; PEN::SUB0]; 0]}

  / ── Convenience shape paths (all record into the current path, like moveTo/lineTo) ──
  / Axis-aligned rectangle as a closed subpath.
  rect:{[x;y;w;h] moveTo[x;y]; lineTo[x+w;y]; lineTo[x+w;y+h]; lineTo[x;y+h]; close[]}
  / Ellipse centred (cx,cy) with radii (rx,ry) — four cubic Béziers (kappa≈0.5523), closed.
  ellipse:{[cx;cy;rx;ry]
    k:0.5522847498
    moveTo[cx+rx; cy]
    cubicTo[cx+rx; cy+k*ry; cx+k*rx; cy+ry; cx; cy+ry]
    cubicTo[cx-k*rx; cy+ry; cx-rx; cy+k*ry; cx-rx; cy]
    cubicTo[cx-rx; cy-k*ry; cx-k*rx; cy-ry; cx; cy-ry]
    cubicTo[cx+k*rx; cy-ry; cx+rx; cy-k*ry; cx+rx; cy]
    close[]}
  / Circle of radius r.
  circle:{[cx;cy;r] ellipse[cx;cy;r;r]}

  / ── Text (analytic Slug coverage — resolution-independent, antialiased) ──────
  / cnv.text[face; sz; str; paint] lays str's glyphs left-to-right from the current
  / pen (its baseline-left origin, e.g. set with moveTo) at pixel size sz, coloured by
  / paint's inner colour. Glyphs are RECORDED here and rendered by cnv.render through
  / lib/slug.k's SCENE-BUFFER path (same as the solid fills): each glyph's raw quadratic
  / outline bins into the frame's shared curve buffer and draws as a bbox quad with
  / per-pixel Bézier coverage + AA. No kerning/ligatures.
  / Per-glyph state is deliberately thin. Face, size, colour and clip are CONSTANT across
  / one cnv.text call, so they are resolved ONCE here — the face and size to small registry
  / indices (matching a face value costs ~2 ms, far too much to do per glyph), the paint to
  / its finished 44-float block. What each glyph then carries is an int CACHE KEY and a
  / reference to that shared block, which is what lets the render pass run vectorised.
  TXGID:  0#0    / per-glyph glyph id
  TXKEY:  0#0    / per-glyph glyph-cache key = gid + 65536*(sizeIdx + NSIZE*faceIdx)
  TXPB:   ()     / per-glyph paint block (shared per cnv.text call)
  TXPX:   0#0.   / per-glyph pen x (local)
  TXPY:   0#0.   / per-glyph pen y (local baseline)
  TXXF:   ()     / per-glyph transform (2×3)
  TXFACES: ()    / face registry (persistent; the cache key indexes it)
  TXFIDS: 0#`    / …keyed by face NAME, because `?` cannot look up a face value: given a
  TXSIZES: 0#0.  / non-atomic right argument it VECTORISES over it instead of matching it
                 / whole (and `~` on two faces deep-compares the font — ~2 ms a go).
  / The key packs (faceIdx<16; sizeIdx<1024; gid<65536) into an i32, so both registries
  / are capped; a full one reuses its last slot rather than overflowing into another
  / field's bits. gcSweep (at frame start, where nothing is recorded yet) drops the whole
  / cache once it or the size registry grows large, so an app that animates text size
  / continuously recycles instead of leaking.
  NFACE: 16
  NSIZE: 1024
  GCAP:  4096                                   / cached glyphs before a sweep
  regFace:{[f]
    nm:`s$font.fullName f; i:TXFIDS?nm
    $[i<#TXFIDS;     i
      NFACE>#TXFIDS; [TXFIDS::TXFIDS,nm; TXFACES::TXFACES,,f; (#TXFIDS)-1]
      NFACE-1]}
  regSize:{[s]
    i:TXSIZES?s
    $[i<#TXSIZES;    i
      NSIZE>#TXSIZES;[TXSIZES::TXSIZES,s; (#TXSIZES)-1]
      NSIZE-1]}
  gcSweep:{[] $[(GCAP<#GKEY)|(NSIZE-1)<#TXSIZES
                [GKEY::0#0; GBLOB::(); GRECT::(); TXSIZES::0#0.; TXFIDS::0#`; TXFACES::()]
                0]}
  slugText:{[face;sz;gids;paint]
    n:#gids; sc:font.scale[face;sz]; adv:(face`hmtx)`adv; na:#adv
    advPx: sc*adv@(gids & na-1)
    ox:PEN 0; oy:PEN 1
    penXs: ox+0.,+\-1_advPx
    rgba: 4#24_paint                              / paint's inner colour (frag[6])
    blk: applyClipM[gpu.solid[rgba 0; rgba 1; rgba 2; rgba 3]; CLIPM; CLIPE]
    base: 65536*(regSize sz)+NSIZE*regFace face
    TXGID::TXGID,gids; TXKEY::TXKEY,base+gids
    TXPX::TXPX,penXs; TXPY::TXPY,n#oy
    TXPB::TXPB,(n#,blk); TXXF::TXXF,(n#,CTM)
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
  / loadImg[path] → (gpu texture handle; imageW; imageH), all FLOATS (a bare int handle
  / would box the 44-float paint block). image.read auto-loads its module.
  loadImg:{[path] i:image.read path; (0.+texture.upload i; 0.+i`width; 0.+i`height)}
  / Image PAINT (type 1): map the image (from loadImg → (handle;iw;ih)) onto the rect
  / (x,y,w,h) in the current transform space, tinted by rgba (use 1 1 1 1 for the plain
  / image). paintMat = inverse(CTM ∘ image→rect), extent = (iw,ih) so paintMat·fpos/extent
  / is the [0,1] uv. The texture HANDLE rides in frag[10].z (off+42); the draw pass reads
  / it, binds the image, and routes the fill to slug.FRAGFI (which samples it × coverage).
  image:{[img;x;y;w;h;rgba]
    hnd:img 0; iw:img 1; ih:img 2
    pm:invAffine mul[CTM; (w%iw),0.,0.,(h%ih),x,y]
    ,/((1. 0. 0. 0. 0. 1. 0. 0. 0. 0. 1. 0.); matCols pm; rgba; 0. 0. 0. 0.; 1e10 1e10 1. 1.; iw,ih,0.,0.; 0.,1.,hnd,0.)}
  / Clip subsequent draws to rect (x,y,w,h) in the current transform space. Scoped
  / by save/restore (REPLACES, does not intersect). Reset early with cnv.noClip.
  clip:{[x;y;w;h]
    c2s:mul[CTM; 1.,0.,0.,1.,(x+0.5*w),(y+0.5*h)]
    CLIPM::invAffine c2s
    CLIPE::(0.5*w),(0.5*h),sqrt[((CTM 0)*(CTM 0))+((CTM 1)*(CTM 1))],sqrt[((CTM 2)*(CTM 2))+((CTM 3)*(CTM 3))]}
  noClip:{[] CLIPM::1. 0. 0. 1. 0. 0.; CLIPE::1e10 1e10 1. 1.}
  / Bake a clip (scissorMat @ frag[0..2], scissorExt/scale @ frag[8]) into a paint.
  / No clip ⇒ identity/huge ⇒ no-op. applyClip uses the ACTIVE clip; applyClipM takes an
  / explicit (matrix;ext) so text can bake the clip that was live at record time.
  applyClipM:{[p;clm;cle] @[@[p; !12; :; matCols clm]; 32+!4; :; cle]}
  applyClip:{[p] applyClipM[p; CLIPM; CLIPE]}
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
  / qCorners[cl;m;ox;oy] → (clip4; screen4; aa): uv-rect cl offset by (ox,oy) in local space,
  / transformed by m → 4 SCREEN + 4 clip corners; per-draw AA ≈1.2 screen px (in uv).
  qCorners:{[cl;m;ox;oy]
    sa:toScreen[m; ox+cl 0; oy+cl 3]; sb:toScreen[m; ox+cl 2; oy+cl 3]
    sc:toScreen[m; ox+cl 2; oy+cl 1]; sd:toScreen[m; ox+cl 0; oy+cl 1]
    ca:scrClip sa; cb:scrClip sb; cc:scrClip sc; cd:scrClip sd
    e:cb-ca; cw:1e-6|sqrt[((e 0)*(e 0))+((e 1)*(e 1))]
    ((ca;cb;cc;cd); (sa;sb;sc;sd); 2.4%(cw*SFW))}
  / draw one scene-buffer fill (gradient/solid/clip via FRAGF) or image fill (via FRAGFI).
  drawQuad:{[off;cl;m;ox;oy] q:qCorners[cl;m;ox;oy]; slug.fillDraw[q 0; q 1; off; q 2]}
  drawImgQ:{[off;cl;m;ox;oy;tex] q:qCorners[cl;m;ox;oy]; slug.fillDrawImg[q 0; q 1; off; q 2; tex]}

  / ── Slug text pass — glyphs ride the SAME scene buffer as fills/strokes ─────────
  / Each glyph's raw quadratic outline (font.quads) is just another fill (a SOLID paint of
  / the glyph colour): scanText bins the whole frame's glyphs during the accumulate phase,
  / drawGlyphS draws each bbox quad, the fragment reads the curves back for coverage + AA.
  / Coverage quads are SQUARES (aspect-preserving normalise) that overlap when packed, so
  / correct text needed the pull pipeline's depth relaxed to LESS_OR_EQUAL (see vk.zig).
  TXOFF:  0#0.   / per-glyph scene-buffer offset (-1 = empty glyph, e.g. space: skip)
  TXRECT: ()     / per-glyph uv-square rect in glyph pixel space (from addFill)
  / GLYPH CACHE (persistent across frames). A glyph's banded curve data depends only on
  / (face; size; gid) — never on colour or position — so it is built once and reused. Without
  / it every frame re-extracts each outline (font.quads) and re-bins it into bands: ~310 ms
  / for a screenful of text, which is what made a text editor feel laggy to type in.
  / A space/empty glyph has no contours — banding it would fold min/max over an empty point
  / set and poison the buffer — so it caches an EMPTY blob and addFillN gives it the -1 skip
  / sentinel. Cache misses are built from the key, which carries the registry indices.
  GKEY:  0#0     / cache keys
  GBLOB: ()      / banded curve data per key (empty ⇒ blank glyph)
  GRECT: ()      / uv-square rect per key
  keyFace:{[k] TXFACES[(k div 65536) div NSIZE]}
  keySize:{[k] TXSIZES[(k div 65536) mod NSIZE]}
  cacheAdd:{[k] cs: font.quads[keyFace k; k mod 65536; keySize k]
    GKEY::GKEY,k; GRECT::GRECT,,$[0<#cs; slug.rectOf[cs;0.14]; 0. 0. 0. 0.]
    GBLOB::GBLOB,,$[0<#cs; slug.bandDataC[cs;0.14]; 0#0.]}
  / Whole text pass at once: fill the cache for keys it has not seen, then look every glyph
  / up and hand the batch to slug.addFillN, which joins the frame's glyph data in ONE go.
  scanText:{[] u:?TXKEY; m:u@&(GKEY?u)=#GKEY; z:cacheAdd'm; scanTextJ GKEY?TXKEY}
  scanTextJ:{[j] TXRECT::GRECT@j; TXOFF::slug.addFillN[TXPB; GBLOB@j]}
  drawGlyphS:{[i] drawQuad[TXOFF i; TXRECT i; TXXF i; TXPX i; TXPY i]}
  drawTStep:{[i] $[(TXOFF i)<0.; 0; drawGlyphS i]; drawText i+1}
  drawText:{[i] $[i<#TXGID; drawTStep i; 0]}

  / ── Unified scene-buffer draw pass (fills + strokes, in ops-table order) ────────
  / EVERY fill/stroke bins its curves + 44-float paint block into the ONE scene buffer; the
  / fragment reads the curves for coverage AND evaluates the paint (gradient/solid + baked
  / clip) at its screen pos. No tessellation. Fills = local contours + drawM; strokes = a
  / SCREEN-space offset outline (so width is screen px) + identity transform.
  DOFF: 0#0.; DRECT: (); DXF: (); DTEX: 0#0   / DTEX k = image texture handle (0 = not an image)
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
  / paint frag[10] = (texType; type; handle; blur). type 1 = image; handle at index 42.
  addDraw:{[i]
    p: PAINTS PIDX i
    r: slug.addFill[drawCs i; 0.14; p]
    DOFF::DOFF,r 0; DRECT::DRECT,,r 1; DXF::DXF,,drawXf i; DTEX::DTEX,$[0.5<p 41; `i$p 42; 0]}
  scanStep:{[i] addDraw i; scanDraws i+1}
  scanDraws:{[i] $[i<ndraws[]; scanStep i; 0]}
  drawOne:{[k] $[0<DTEX k; drawImgQ[DOFF k; DRECT k; DXF k; 0.; 0.; DTEX k]; drawQuad[DOFF k; DRECT k; DXF k; 0.; 0.]]}
  drawStep:{[k] drawOne k; drawFrom k+1}
  drawFrom:{[k] $[k<#DOFF; drawStep k; 0]}
  / render[w;h] — fills + strokes + text, ALL analytic through the ONE Slug scene buffer:
  / accumulate every draw's curves+paint → upload once → draw (fills/strokes in ops order,
  / then text on top). w,h = framebuffer size (= the fragment's screen space for paints).
  render:{[w;h]
    DOFF::0#0.; DRECT::(); DXF::(); DTEX::0#0; TXOFF::0#0.; TXRECT::(); SFW::w; SFH::h
    slug.sceneBegin[]
    $[0<ndraws[]; scanDraws 0; 0]
    $[0<#TXGID; scanText[]; 0]
    $[(0<#DOFF)|(0<#TXGID); slug.sceneFlush[]; 0]
    $[0<#DOFF; drawFrom 0; 0]
    $[0<#TXGID; drawText 0; 0]}
\d

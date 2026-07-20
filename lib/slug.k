/ lib/slug.k — GPU analytic vector coverage (Slug-style), Phase 1 + band acceleration.
/
/ Build first:  zig build gpu
/ Load with:    2: "lib/slug.k"
/
/ WHAT THIS IS
/ ------------
/ Resolution-independent glyph/shape rendering with NO tessellation: a shape's RAW
/ quadratic Béziers (font.quads) are packed into a float DATA TEXTURE, and a fragment
/ shader computes per-pixel coverage analytically — for each pixel it loops the curves,
/ finds the horizontal-ray crossings, and accumulates signed (nonzero-winding) coverage
/ with 1px antialiasing. Same family as Eric Lengyel's Slug (patent released) and
/ Loop-Blinn / Dobbie GPU font rendering. The shader handles TRUE quadratics (curves
/ stay smooth at any zoom) with a robust line fallback for a≈0 segments.
/
/ BAND ACCELERATION
/ -----------------
/ The glyph's y-range [0,1] is split into slugNB horizontal BANDS. A curve is stored
/ in every band its (true, extremum-aware) y-extent overlaps, and each band holds at
/ most slugMPB curves. A pixel picks its band from py and loops only slugMPB slots —
/ so the per-pixel cost is fixed and small regardless of total glyph complexity
/ (instead of looping every curve). Data texture is 2-D: one ROW per band.
/
/ Enabled by: fragment-shader bounded loops (dye rsum in the fragment path) and a
/ NEAREST-sampled R32G32B32A32_SFLOAT data texture (gpu.textureF) for exact per-texel
/ reads via sample[] at texel centres (no texelFetch needed).
/
/ DATA LAYOUT
/ -----------
/ A (slugTW × slugNB) texture, slugTW = 2*slugMPB. Row b = band b; within a row, curve
/ j occupies texels 2j = (x0,y0,cx,cy) and 2j+1 = (x2,y2,0,0). Empty slots padded far
/ away (5.0) so they never cross a pixel.
/
/ STATUS / LIMITS
/ ---------------
/ slugNB/MPB/TW/AA are baked shader constants (slugTW must = 2*slugMPB). Bands over
/ slugMPB curves truncate (raise slugMPB). TrueType/glyf only (font.quads; CFF cubic →
/ TODO). AA is a baked uv width (dFdx would make it zoom-exact). Vertical AA on long
/ horizontal edges is limited (winding gives horizontal AA); fine for real outlines.

2: "lib/gpu.k"

/ Baked shader constants (BARE globals so the dye constant-baker resolves them by name).
slugNB:  16.       / bands (rows)
slugMPB: 24        / max curves per band = per-pixel loop length
slugTW:  48.       / texture width in texels = 2*slugMPB
slugAA:  0.004     / antialias ramp width (uv)

\d slug glyph upload pipe draw quad cell tex begin drawCell

  / ── Per-glyph band-build scratch (globals: the mapped builders can't close) ───
  BC:  ()          / list of 8-float texel records, one per curve
  BLO: 0#0.        / per-curve lowest overlapping band
  BHI: 0#0.        / per-curve highest overlapping band

  / Normalise a flat [x y …] buffer into [pad,1-pad]² (aspect-preserving; y flipped
  / from font y-down to uv y-up). Quad control points are just points.
  normC:{[c;mx;my;s;pad]
    nn:(#c)div 2; ix:2*!nn; xs:c@ix; ys:c@ix+1
    nx: pad+(((xs-mx)%s)*(1.-2.*pad))
    ny: (1.-pad)-(((ys-my)%s)*(1.-2.*pad))
    ,/+(nx;ny)}
  / True y-extent (ymin;ymax) of a normalised quad [x0 y0 cx cy x1 y1], including the
  / interior y-extremum if the control bends the curve past its endpoints.
  yext:{[q]
    y0:q 1; cy:q 3; y2:q 5
    a:(y0-(2.*cy))+y2
    ymn:y0&y2; ymx:y0|y2
    te:(y0-cy)%(a+$[a=0.;1.;0.])
    ie:(te>0.)&(te<1.)&(~a=0.)
    ye:(((1.-te)*(1.-te))*y0)+((2.*(1.-te)*te)*cy)+((te*te)*y2)
    (ymn&$[ie;ye;ymn]; ymx|$[ie;ye;ymx])}
  / Band b's row: the (≤slugMPB) curves whose [BLO,BHI] covers b, flattened + padded.
  oneBand:{[b]
    sel: &((~(BLO>b))&(~(b>BHI)))
    n: (#sel)&slugMPB
    picked: $[n>0; ,/BC@n#sel; 0#0.]
    picked,((slugMPB-n)*8)#5.}
  / glyph[face; gid; sz; pad] → banded curve texture data (slugNB rows × slugTW texels).
  glyph:{[face;gid;sz;pad]
    cs: font.quads[face; gid; sz]
    allp:,/cs; nn:(#allp)div 2; ix:2*!nn; xs:allp@ix; ys:allp@ix+1
    mx:&/xs; my:&/ys; s:(|/xs-mx)|(|/ys-my); nc:#cs
    ncs: normC'[cs; nc#mx; nc#my; nc#s; nc#pad]        / normalise contours (no closure)
    quads: ,/ {[c] (6*!(#c)div 6)_c}' ncs              / list of 6-float quads (all contours)
    BC:: {[q] q,0. 0.}' quads                           / 8-float texel record per curve
    yy: +yext' quads                                    / (ymins; ymaxs)
    BLO:: 0.|((slugNB-1.)&(_ slugNB*yy 0))             / band range per curve (clamped)
    BHI:: 0.|((slugNB-1.)&(_ slugNB*yy 1))
    ,/[oneBand'(0.+!`i$slugNB)]}                        / slugNB rows, flattened row-major
  upload:{[data] gpu.textureF[`i$(slugTW; slugNB); data]}   / → 2-D texture handle

  / ── Geometry + shaders ───────────────────────────────────────────────────────
  / A clip-space rect → 6 verts of (clipX,clipY, u,v) (stride 4); uv spans the full
  / glyph [0,1]² regardless of where the rect sits on screen.
  quad:{[x0;y0;x1;y1] x0,y0,0.,0., x1,y0,1.,0., x1,y1,1.,1., x0,y0,0.,0., x1,y1,1.,1., x0,y1,0.,1.}
  VTX: shader.vertexPull[[wUv:`v2]; {[qb;vid]
    b:4.*vid; px:qb[b]; py:qb[b+1.]
    ((px;py;0.5;1.0); (qb[b+2.]; qb[b+3.]))}]
  / Fragment: pick the band from py, then loop only that band's slugMPB slots. For each
  / quadratic (p0, control, p2) count signed horizontal-ray crossings (nonzero winding)
  / with 1px AA. Branchless by |a|: QUAD path solves B_y(t)=py for both roots (turning
  / points cancel by sign, x_cross from full quadratic B_x → smooth at any zoom); LINE
  / path (a≈0, ill-conditioned) uses the linear root + half-open-y rule (vertex/
  / horizontal-safe). clamp(|Σ signed|) = nonzero-winding fill (holes work).
  FRAG: shader.fragmentTexN[[wUv:`v2; out:`v4]; 1; {[wUv]
    px: wUv[0]; py: wUv[1]
    band: clamp[floor[py*slugNB]; 0.; slugNB-1.]
    vrow: (band+0.5)%slugNB
    cov: rsum[slugMPB; {[j]
      ta: sample[0; (((2.*j)+0.5)%slugTW; vrow)]
      tb: sample[0; (((2.*j)+1.5)%slugTW; vrow)]
      x0:ta[0]; y0:ta[1]; cx:ta[2]; cy:ta[3]; x2:tb[0]; y2:tb[1]
      a: (y0-(2.*cy))+y2
      b: 2.*(cy-y0)
      c: y0-py
      isLine: 1.-step[1e-4; abs[a]]
      aq: a+(isLine*1.)
      disc: (b*b)-(4.*aq*c)
      sq: sqrt[max[disc;0.]]
      inv: 1.%(2.*aq)
      tq1: ((0.-b)-sq)*inv
      tq2: ((0.-b)+sq)*inv
      bl: b+((1.-step[1e-6;abs[b]])*1e-6)
      tll: (py-y0)%bl
      t1: mix[tq1; tll; isLine]
      t2: mix[tq2; 9.; isLine]
      u1: 1.-t1; u2: 1.-t2
      xc1: (((u1*u1)*x0)+(2.*u1*t1*cx))+((t1*t1)*x2)
      xc2: (((u2*u2)*x0)+(2.*u2*t2*cx))+((t2*t2)*x2)
      gq1: (step[0.;disc]*step[0.;t1])*(1.-step[1.;t1])
      gq2: (step[0.;disc]*step[0.;t2])*(1.-step[1.;t2])
      gl: step[min[y0;y2];py]*(1.-step[max[y0;y2];py])
      g1: mix[gq1; gl; isLine]
      g2: (1.-isLine)*gq2
      w1: mix[sign[(2.*aq*t1)+b]; sign[y2-y0]; isLine]
      w2: sign[(2.*aq*t2)+b]
      r1: clamp[(0.5+((xc1-px)%slugAA)); 0.; 1.]
      r2: clamp[(0.5+((xc2-px)%slugAA)); 0.; 1.]
      ((g1*w1)*r1)+((g2*w2)*r2)}]
    ins: clamp[abs[cov]; 0.; 1.]
    (ins;ins;ins;1.0)}]

  / ── Pipeline + draw (standalone: white, clip-space; see demo/slug.k) ─────────
  pipe:{[] mesh.compilePull[VTX; FRAG]}
  / Draw one glyph: `vb` = a resident buffer holding its slug.quad, `tex` = a 1-element
  / list with its curve-texture handle. Each glyph needs its OWN vb (deferred submission).
  draw:{[pl; vb; tex] mesh.drawPullT[pl; (,vb); 6; tex]}

  / ── Coloured, pixel-space, composited variant (for Canvas text) ──────────────
  / Because slug.glyph normalises the outline, the curve texture is SIZE-INDEPENDENT
  / (size only scales the on-screen quad), so textures cache by glyph id alone.
  SLPAD:  0.14                        / normalise padding for cached glyph textures
  SLKEY:  0#0                         / cached glyph ids (I)
  SLTEX:  0#0                         / their texture handles (I)
  SLPIPE: 0                           / lazy coloured pipeline
  SLVIEW: 0                           / viewSize uniform buffer
  SLQPOOL: 0#0                        / per-glyph quad-buffer pool (deferred submission)
  SLQI:   0                           / pool cursor (reset each frame in begin)
  buildTex:{[face;gid] h: upload glyph[face;gid;100.;SLPAD]; SLKEY::SLKEY,gid; SLTEX::SLTEX,h; h}
  / tex[face;gid] → cached curve-texture handle (built once per glyph id).
  tex:{[face;gid] i:SLKEY?gid; $[i<#SLKEY; SLTEX i; buildTex[face;gid]]}
  / cell[face;gid;sz] → the glyph's uv-square in glyph pixel space (y-down, baseline
  / at 0, pen at x=0): (sqx0; sqTop; sqx1; sqBot). uv(0,0)↔(sqx0,sqBot), uv(1,1)↔(sqx1,sqTop).
  cell:{[face;gid;sz]
    cs: font.quads[face; gid; sz]
    allp:,/cs; nn:(#allp)div 2; ix:2*!nn; xs:allp@ix; ys:allp@ix+1
    mx:&/xs; my:&/ys; s:(|/xs-mx)|(|/ys-my); sc:s%(1.-2.*SLPAD)
    (mx-(SLPAD*sc); my-(SLPAD*sc); mx+((1.-SLPAD)*sc); my+((1.-SLPAD)*sc))}
  / stride-8 quad [px py u v r g b a]×6 (2 tris) from 4 screen-pixel corners
  / (a=uv00 b=uv10 c=uv11 d=uv01) + colour col (rgba); positions already CTM'd.
  quadC:{[a;b;c;d;col] ,/((a,0. 0.,col); (b,1. 0.,col); (c,1. 1.,col); (a,0. 0.,col); (c,1. 1.,col); (d,0. 1.,col))}
  VTXC: shader.vertexPull[[wUv:`v2; wCol:`v4]; {[qb;ub;vid]
    b:8.*vid; px:qb[b]; py:qb[b+1.]
    cx:((2.*px)%ub[0.])-1.; cy:1.-((2.*py)%ub[1.])
    ((cx;cy;0.5;1.0); (qb[b+2.];qb[b+3.]); (qb[b+4.];qb[b+5.];qb[b+6.];qb[b+7.]))}]
  / Same band coverage as FRAG, but tinted by the interpolated vertex colour and
  / composited via the pipeline's SRC_ALPHA blend (coverage → alpha).
  FRAGC: shader.fragmentTexN[[wUv:`v2; wCol:`v4; out:`v4]; 1; {[wUv;wCol]
    px: wUv[0]; py: wUv[1]
    band: clamp[floor[py*slugNB]; 0.; slugNB-1.]
    vrow: (band+0.5)%slugNB
    cov: rsum[slugMPB; {[j]
      ta: sample[0; (((2.*j)+0.5)%slugTW; vrow)]
      tb: sample[0; (((2.*j)+1.5)%slugTW; vrow)]
      x0:ta[0]; y0:ta[1]; cx:ta[2]; cy:ta[3]; x2:tb[0]; y2:tb[1]
      a: (y0-(2.*cy))+y2
      b: 2.*(cy-y0)
      c: y0-py
      isLine: 1.-step[1e-4; abs[a]]
      aq: a+(isLine*1.)
      disc: (b*b)-(4.*aq*c)
      sq: sqrt[max[disc;0.]]
      inv: 1.%(2.*aq)
      tq1: ((0.-b)-sq)*inv
      tq2: ((0.-b)+sq)*inv
      bl: b+((1.-step[1e-6;abs[b]])*1e-6)
      tll: (py-y0)%bl
      t1: mix[tq1; tll; isLine]
      t2: mix[tq2; 9.; isLine]
      u1: 1.-t1; u2: 1.-t2
      xc1: (((u1*u1)*x0)+(2.*u1*t1*cx))+((t1*t1)*x2)
      xc2: (((u2*u2)*x0)+(2.*u2*t2*cx))+((t2*t2)*x2)
      gq1: (step[0.;disc]*step[0.;t1])*(1.-step[1.;t1])
      gq2: (step[0.;disc]*step[0.;t2])*(1.-step[1.;t2])
      gl: step[min[y0;y2];py]*(1.-step[max[y0;y2];py])
      g1: mix[gq1; gl; isLine]
      g2: (1.-isLine)*gq2
      w1: mix[sign[(2.*aq*t1)+b]; sign[y2-y0]; isLine]
      w2: sign[(2.*aq*t2)+b]
      r1: clamp[(0.5+((xc1-px)%slugAA)); 0.; 1.]
      r2: clamp[(0.5+((xc2-px)%slugAA)); 0.; 1.]
      ((g1*w1)*r1)+((g2*w2)*r2)}]
    ins: clamp[abs[cov]; 0.; 1.]
    (wCol[0]; wCol[1]; wCol[2]; ins*wCol[3])}]
  pipeC:{[] mesh.compilePull[VTXC; FRAGC]}
  / begin[w;h] — call once per frame before drawCell: lazy pipeline, refresh the
  / viewSize uniform, reset the quad-buffer pool cursor.
  begin:{[w;h]
    $[SLPIPE=0; SLPIPE::pipeC[]; 0]
    $[SLVIEW=0; SLVIEW::gpu.buffer[w,h,0. 0.]; gpu.write[SLVIEW; w,h,0. 0.]]
    SLQI::0}
  grow:{[] SLQPOOL::SLQPOOL,gpu.buffer[48#0.]}     / +1 quad buffer (6 verts × 8)
  nextBuf:{[] $[SLQI<#SLQPOOL; 0; grow[]]; b:SLQPOOL SLQI; SLQI::SLQI+1; b}
  / drawCell[a;b;c;d;col;tex] — one glyph: 4 screen-pixel corners + rgba + its texture
  / (1-element handle list). Uses a fresh pooled buffer (deferred submission needs
  / a distinct buffer per draw). begin[w;h] must have run this frame.
  drawCell:{[a;b;c;d;col;tex]
    vb: nextBuf[]
    gpu.write[vb; quadC[a;b;c;d;col]]
    mesh.drawPullT[SLPIPE; (vb;SLVIEW); 6; tex]}
\d

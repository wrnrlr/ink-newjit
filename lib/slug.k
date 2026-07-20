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
/ TWO CONSUMPTION PATHS
/ ---------------------
/ (1) DATA-TEXTURE path (glyph/upload/pipe/draw/quad + VTX/FRAG): one curve texture per
/     shape, drawn white in clip space. Used by the standalone demo/slug.k.
/ (2) SCENE-BUFFER path (sceneBegin/addFill/sceneFlush/fillDraw + VTXF/FRAGF): ALL of a
/     frame's fills — solid shapes AND text glyphs — bin their curves into ONE resident
/     StorageBuffer (gpu.write once/frame); each fill draws a clip-space bbox quad whose
/     fragment reads its curves back by offset. This is what lib/canvas.k uses for both
/     fills and text: no per-shape textures, handles unlimited repeats, dynamic geometry.
/     (The older coloured per-glyph texture path was removed as redundant — one backend.)
/
/ STATUS / LIMITS
/ ---------------
/ slugNB/MPB/TW/AA are baked shader constants (slugTW must = 2*slugMPB). Bands over
/ slugMPB curves truncate (raise slugMPB). TrueType/glyf only (font.quads; CFF cubic →
/ TODO). AA is a baked uv width (dFdx would make it zoom-exact). Vertical AA on long
/ horizontal edges is limited (winding gives horizontal AA); fine for real outlines.
/ Scene buffer pads every fill to slugNB*slugMPB*8 floats (SCCAP caps total/frame).

2: "lib/gpu.k"

/ Baked shader constants (BARE globals so the dye constant-baker resolves them by name).
slugNB:  16.       / bands (rows)
slugMPB: 24        / max curves per band = per-pixel loop length
slugTW:  48.       / texture width in texels = 2*slugMPB
slugAA:  0.004     / antialias ramp width (uv)

\d slug glyph upload pipe draw quad rectOf sceneBegin addFill sceneFlush fillDraw

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
  / bandData[cs; pad] → banded curve data (slugNB rows × slugMPB curves × 8 floats,
  / row-major), for ANY list of quadratic contour buffers [x0 y0 cx cy x1 y1 …] — glyph
  / outlines or arbitrary canvas paths. Normalises into [pad,1-pad]² and bins by y-extent.
  bandData:{[cs;pad]
    allp:,/cs; nn:(#allp)div 2; ix:2*!nn; xs:allp@ix; ys:allp@ix+1
    mx:&/xs; my:&/ys; s:(|/xs-mx)|(|/ys-my); nc:#cs
    ncs: normC'[cs; nc#mx; nc#my; nc#s; nc#pad]
    quads: ,/ {[c] (6*!(#c)div 6)_c}' ncs
    BC:: {[q] q,0. 0.}' quads
    yy: +yext' quads
    BLO:: 0.|((slugNB-1.)&(_ slugNB*yy 0)); BHI:: 0.|((slugNB-1.)&(_ slugNB*yy 1))
    ,/[oneBand'(0.+!`i$slugNB)]}
  / The [pad,1-pad] uv-square in the contours' own coordinate space (sqx0;sqTop;sqx1;sqBot).
  rectOf:{[cs;pad]
    allp:,/cs; nn:(#allp)div 2; ix:2*!nn; xs:allp@ix; ys:allp@ix+1
    mx:&/xs; my:&/ys; s:(|/xs-mx)|(|/ys-my); sc:s%(1.-2.*pad)
    (mx-(pad*sc); my-(pad*sc); mx+((1.-pad)*sc); my+((1.-pad)*sc))}
  glyph:{[face;gid;sz;pad] bandData[font.quads[face;gid;sz]; pad]}
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

  / ── Scene-buffer fill path (arbitrary paths → ONE resident buffer, no textures) ──
  / The frame's fill curves accumulate host-side (SCACC), upload once (sceneFlush), and
  / each fill draws a clip-space bbox quad whose fragment reads its curves from the shared
  / scene buffer at the fill's offset — enabled by shader.fragmentBuf (fragment reads a
  / StorageBuffer). No per-shape textures, no cache: one gpu.write per frame.
  SCACC:  0#0.       / this frame's concatenated banded curve data (host side)
  SCENE:  0          / resident scene buffer
  SCCAP:  262144     / scene buffer capacity (floats)
  SCPIPE: 0          / buffer-based fill pipeline
  SCQPOOL: 0#0       / per-fill quad-buffer pool
  SCQI:   0
  sceneBegin:{[]
    SCACC:: 0#0.; SCQI:: 0
    $[SCPIPE=0; SCPIPE:: mesh.compilePull[VTXF; FRAGF]; 0]
    $[SCENE=0; SCENE:: gpu.buffer[SCCAP#0.]; 0]}
  / addFill[cs; pad] → (float-offset into scene buffer; local uv-square rect); appends data.
  / off is a FLOAT (0.+#SCACC) — a bare int would box the stride-10 vertex join to a list.
  addFill:{[cs;pad] off:0.+#SCACC; SCACC:: SCACC,bandData[cs;pad]; (off; rectOf[cs;pad])}
  sceneFlush:{[] gpu.write[SCENE; SCACC]}                / upload the whole frame's curves
  scGrow:{[] SCQPOOL:: SCQPOOL,gpu.buffer[60#0.]}        / 6 verts × 10 floats
  scNext:{[] $[SCQI<#SCQPOOL; 0; scGrow[]]; b:SCQPOOL SCQI; SCQI::SCQI+1; b}
  / stride-10 quad [clipX clipY u v aa off r g b a]×6 from 4 CLIP-space corners.
  fillQuad:{[a;b;c;d;aa;off;col] ,/((a,0.,0.,aa,off,col); (b,1.,0.,aa,off,col); (c,1.,1.,aa,off,col); (a,0.,0.,aa,off,col); (c,1.,1.,aa,off,col); (d,0.,1.,aa,off,col))}
  / fillDraw[a;b;c;d;aa;off;col] — one fill: 4 CLIP corners, AA width (uv), scene offset, rgba.
  fillDraw:{[a;b;c;d;aa;off;col]
    vb: scNext[]
    gpu.write[vb; fillQuad[a;b;c;d;aa;off;col]]
    mesh.drawPull[SCPIPE; (vb;SCENE); 6]}
  / Vertex pulls the stride-10 quad from binding 0; scene buffer (binding 1) unused here.
  VTXF: shader.vertexPull[[wUvA:`v4; wCol:`v4]; {[qbuf; sbuf; vid]
    b:10.*vid
    ((qbuf[b]; qbuf[b+1.]; 0.5; 1.0); (qbuf[b+2.]; qbuf[b+3.]; qbuf[b+4.]; qbuf[b+5.]); (qbuf[b+6.]; qbuf[b+7.]; qbuf[b+8.]; qbuf[b+9.]))}]
  / Fragment reads this fill's curves from the scene buffer (binding 1) at base = off +
  / band*slugMPB*8, same analytic band+coverage math as FRAG. qbuf (binding 0) declared, unused.
  FRAGF: shader.fragmentBuf[[wUvA:`v4; wCol:`v4; out:`v4]; 2; {[wUvA; wCol; qbuf; sbuf]
    px: wUvA[0]; py: wUvA[1]; aa: wUvA[2]
    / off is one integer for the whole quad, but passed as an interpolated varying —
    / barycentric fp gives off·(b0+b1+b2) with the sum ≠ 1.0 by ~1e-7, so a bare truncating
    / buffer index (sbuf[off+…]) can land one slot low → reads the PREVIOUS fill's curves
    / (glyphs dropped/half at some sizes/positions). Round to recover the exact integer.
    off: floor[wUvA[3]+0.5]
    band: clamp[floor[py*slugNB]; 0.; slugNB-1.]
    base: off+(band*(slugMPB*8.))
    cov: rsum[slugMPB; {[j]
      o: base+(j*8.)
      x0:sbuf[o]; y0:sbuf[o+1.]; cx:sbuf[o+2.]; cy:sbuf[o+3.]; x2:sbuf[o+4.]; y2:sbuf[o+5.]
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
      r1: clamp[(0.5+((xc1-px)%aa)); 0.; 1.]
      r2: clamp[(0.5+((xc2-px)%aa)); 0.; 1.]
      ((g1*w1)*r1)+((g2*w2)*r2)}]
    ins: clamp[abs[cov]; 0.; 1.]
    (wCol[0]; wCol[1]; wCol[2]; ins*wCol[3])}]
\d

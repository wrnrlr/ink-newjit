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
slugPS:  44.       / scene-buffer per-fill PAINT-block stride (NanoVG FragUniforms floats)

\d slug glyph upload pipe draw quad rectOf sceneBegin addFill sceneFlush fillDraw

  / ── Per-glyph band-build scratch (globals: the mapped builders can't close) ───
  BC:  ()          / list of 8-float texel records, one per curve
  BLO: 0#0.        / per-curve lowest overlapping band
  BHI: 0#0.        / per-curve highest overlapping band

  / Normalise a flat [x y …] buffer into [pad,1-pad]² (y flipped from font y-down to uv
  / y-up). x and y scale INDEPENDENTLY (sx,sy) — NOT aspect-preserving — so a wide/flat
  / shape (a stroke, a thin bar) fills the full uv-y range and its curves spread across ALL
  / bands instead of cramming into a few (which truncates at slugMPB). The non-square quad
  / (rectOf uses the same sx,sy) exactly undoes the stretch, so coverage stays correct.
  normC:{[c;mx;my;sx;sy;pad]
    nn:(#c)div 2; ix:2*!nn; xs:c@ix; ys:c@ix+1
    nx: pad+(((xs-mx)%sx)*(1.-2.*pad))
    ny: (1.-pad)-(((ys-my)%sy)*(1.-2.*pad))
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
    mx:&/xs; my:&/ys; sx:1e-6|(|/xs-mx); sy:1e-6|(|/ys-my); nc:#cs
    ncs: normC'[cs; nc#mx; nc#my; nc#sx; nc#sy; nc#pad]
    quads: ,/ {[c] (6*!(#c)div 6)_c}' ncs
    BC:: {[q] q,0. 0.}' quads
    yy: +yext' quads
    BLO:: 0.|((slugNB-1.)&(_ slugNB*yy 0)); BHI:: 0.|((slugNB-1.)&(_ slugNB*yy 1))
    ,/[oneBand'(0.+!`i$slugNB)]}
  / The [pad,1-pad] uv-rect in the contours' own coordinate space (sqx0;sqTop;sqx1;sqBot),
  / matching normC's INDEPENDENT sx,sy so uv maps back exactly (non-square in general).
  rectOf:{[cs;pad]
    allp:,/cs; nn:(#allp)div 2; ix:2*!nn; xs:allp@ix; ys:allp@ix+1
    mx:&/xs; my:&/ys; sx:1e-6|(|/xs-mx); sy:1e-6|(|/ys-my)
    scx:sx%(1.-2.*pad); scy:sy%(1.-2.*pad)
    (mx-(pad*scx); my-(pad*scy); mx+((1.-pad)*scx); my+((1.-pad)*scy))}
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
  / addFill[cs; pad; paint] → (float-offset into scene buffer; local uv-square rect).
  / Appends the fill's 44-float NanoVG paint block (gradient/solid + baked clip) THEN its
  / banded curve data. off is a FLOAT (0.+#SCACC) — a bare int would box the vertex join.
  / Layout per fill: [paint: slugPS floats][bands: slugNB*slugMPB*8 floats]. off → paint.
  addFill:{[cs;pad;paint] off:0.+#SCACC; SCACC:: SCACC,paint,bandData[cs;pad]; (off; rectOf[cs;pad])}
  sceneFlush:{[] gpu.write[SCENE; SCACC]}                / upload the whole frame's curves
  scGrow:{[] SCQPOOL:: SCQPOOL,gpu.buffer[48#0.]}        / 6 verts × 8 floats
  scNext:{[] $[SCQI<#SCQPOOL; 0; scGrow[]]; b:SCQPOOL SCQI; SCQI::SCQI+1; b}
  / stride-8 vertex [clipX clipY u v fx fy off aa]: clip pos for gl_Position, uv for
  / coverage, (fx,fy) = SCREEN/framebuffer pos for the paint & scissor matrices, off, aa.
  fillVert:{[cp;sp;u;v;off;aa] ((cp 0),(cp 1),u,v),((sp 0),(sp 1),off,aa)}
  / clip/scr = 4 corners each (a=uv00 b=uv10 c=uv11 d=uv01); 2 tris (a,b,c, a,c,d).
  fillQuad:{[clip;scr;off;aa]
    a:clip 0; b:clip 1; c:clip 2; d:clip 3; sa:scr 0; sb:scr 1; sc:scr 2; sd:scr 3
    ,/(fillVert[a;sa;0.;0.;off;aa]; fillVert[b;sb;1.;0.;off;aa]; fillVert[c;sc;1.;1.;off;aa]
       fillVert[a;sa;0.;0.;off;aa]; fillVert[c;sc;1.;1.;off;aa]; fillVert[d;sd;0.;1.;off;aa])}
  / fillDraw[clip;scr;off;aa] — one fill: 4 CLIP + 4 SCREEN corners, scene offset, AA (uv).
  fillDraw:{[clip;scr;off;aa]
    vb: scNext[]
    gpu.write[vb; fillQuad[clip;scr;off;aa]]
    mesh.drawPull[SCPIPE; (vb;SCENE); 6]}
  / Vertex pulls the stride-8 quad from binding 0; scene buffer (binding 1) unused here.
  VTXF: shader.vertexPull[[wUvA:`v4; wPos:`v4]; {[qbuf; sbuf; vid]
    b:8.*vid
    ((qbuf[b]; qbuf[b+1.]; 0.5; 1.0); (qbuf[b+2.]; qbuf[b+3.]; qbuf[b+7.]; qbuf[b+6.]); (qbuf[b+4.]; qbuf[b+5.]; 0.; 0.))}]
  / Fragment: analytic coverage (curves at off+slugPS+band*slugMPB*8) × the fill's PAINT.
  / The paint block (off..off+43) is the NanoVG FragUniforms layout; evaluate scissorMask
  / and the gradient/solid paint at (fx,fy) — same math as lib/gpu/fill.frag — and fold
  / into the alpha. So gradients, box/radial paints, and clip all come "for free" per fill.
  FRAGF: shader.fragmentBuf[[wUvA:`v4; wPos:`v4; out:`v4]; 2; {[wUvA; wPos; qbuf; sbuf]
    px: wUvA[0]; py: wUvA[1]; aa: wUvA[2]
    fx: wPos[0]; fy: wPos[1]
    / off is one integer/quad passed as an interpolated varying — barycentric fp gives
    / off·(Σbary) with Σ≠1.0 by ~1e-7, so a bare truncating buffer index can land one slot
    / low → reads the previous fill's data. Round to recover the exact integer.
    off: floor[wUvA[3]+0.5]
    band: clamp[floor[py*slugNB]; 0.; slugNB-1.]
    base: (off+slugPS)+(band*(slugMPB*8.))
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
    / ── paint block @ off (NanoVG FragUniforms mat3s = 3 vec4 .xyz) ──
    / scissorMask(fpos): abs(scissorMat·(fx,fy,1)) - scissorExt, ramp by scissorScale.
    scx: ((sbuf[off]*fx)+(sbuf[off+4.]*fy))+sbuf[off+8.]
    scy: ((sbuf[off+1.]*fx)+(sbuf[off+5.]*fy))+sbuf[off+9.]
    sax: 0.5-((abs[scx]-sbuf[off+32.])*sbuf[off+34.])
    say: 0.5-((abs[scy]-sbuf[off+33.])*sbuf[off+35.])
    scis: clamp[sax;0.;1.]*clamp[say;0.;1.]
    / paint(fpos): paintMat·(fx,fy,1) → paint-local pt; rounded-rect SDF → inner↔outer.
    ptx: ((sbuf[off+12.]*fx)+(sbuf[off+16.]*fy))+sbuf[off+20.]
    pty: ((sbuf[off+13.]*fx)+(sbuf[off+17.]*fy))+sbuf[off+21.]
    extx: sbuf[off+36.]; exty: sbuf[off+37.]; rad: sbuf[off+38.]; feth: sbuf[off+39.]
    dx: abs[ptx]-(extx-rad); dy: abs[pty]-(exty-rad)
    mdx: max[dx;0.]; mdy: max[dy;0.]
    sd: ((min[max[dx;dy];0.])+sqrt[(mdx*mdx)+(mdy*mdy)])-rad
    gd: clamp[(sd+(feth*0.5))%max[feth;1e-4]; 0.; 1.]
    d: (step[0.5;extx])*gd            / extx<0.5 ⇒ solid (d=0 ⇒ innerCol); else gradient
    cr: mix[sbuf[off+24.]; sbuf[off+28.]; d]
    cg: mix[sbuf[off+25.]; sbuf[off+29.]; d]
    cb: mix[sbuf[off+26.]; sbuf[off+30.]; d]
    ca: mix[sbuf[off+27.]; sbuf[off+31.]; d]
    (cr; cg; cb; ((ca*ins)*scis))}]
\d

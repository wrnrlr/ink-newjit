/ test/sword.k — load a binary FBX model (lib/fbx.k) and render just the mesh.
/
/ The mesh comes from data/FBX/Sword.fbx: fbx.read → fbx.trimesh gives a
/ (positions; triangles) pair, which is centred, scaled and flat-shaded into
/ the pbr vertex layout (stride 11: x y z  nx ny nz  r g b rough  lit).
/ All per-frame work (rotation, zoom, pan, normal recompute) is vectorised
/ over the whole mesh — no per-vertex loop.
/
/ Controls:
/   WASD           — pan camera
/   Scroll         — zoom in/out
/   Right-drag X   — rotate scene (Y-axis)
/   Right-drag Y   — tilt scene (X-axis)
/
/ Run: zig build gpu && ink test/sword.k

2: "lib/dye.k"
2: "lib/gpu.k"
2: "lib/fbx.k"
2: "lib/pbr.k"      / shared PBR renderer: pbrVtx + PbrFragment
2: "lib/camera.k"  / orbit camera (WASD pan, scroll zoom, right-drag rotate)

/ ── Material (r g b roughness) ────────────────────────────────────────────────
steel:: 0.62 0.64 0.68 0.35

/ ── Load the FBX mesh once and bake it into model space ───────────────────────
/ Positions are centred + scaled to fit; normals come straight from the FBX file
/ (fbx.mesh → smooth per-polygon-vertex normals) rather than being recomputed, so
/ the sword is smooth-shaded.  Both are triangle soup (3 verts/triangle), aligned.
fbxMesh: {[path]
  t: fbx.read path
  obj: *t@&({$[(x`name)~`Objects;1;0]}'t)
  geo: fbx.get[obj;`Geometry]
  `0 0:"loaded ",(fbx.uname (geo`props)@1)
  m: fbx.mesh geo
  soup: m`pos                       / triangle-soup positions (3 per triangle)
  col: +soup; xs: col@0; ys: col@1; zs: col@2
  cx: 0.5*(&/xs)+(|/xs); cy: 0.5*(&/ys)+(|/ys); cz: 0.5*(&/zs)+(|/zs)   / centre
  sca: 2.4%|/(((|/xs)-(&/xs));((|/ys)-(&/ys));((|/zs)-(&/zs)))
  ( +((sca*xs-cx); (sca*ys-cy); (sca*zs-cz)) ; m`nor )                  / (centred/scaled soup; FBX normals)
}
swData::  fbxMesh "data/FBX/Sword.fbx"
swBase::  swData@0                                        / soup×3 positions (model space)
swNor::   swData@1                                        / soup×3 normals (from the FBX file)
swNT::    (#swBase) div 3                                 / triangle count
swMrep::  (#swBase) # ,steel,1.0                          / per-vertex (mat;lit)

/ ── Static mesh, built once in MODEL space ────────────────────────────────────
/ pos + FBX normal + material, interleaved.  The vertex shader rotates both the
/ position and the normal each frame, so the mesh uploads once and never changes.
swStatic:: ,/swBase,'swNor,'swMrep

/ ── Vertex shader: rotate (Y then X) + zoom + pan + iso projection, all on GPU ─
/ Camera pose arrives as uniforms: uCam = (ca;sa;xca;xsa), uPan = (zoom;cx;cz;_).
/ The position gets zoom+pan; the normal gets the same rotation only (lit in the
/ rotated camera space, matching lib/pbr.k's fixed light directions).
/ Vertex pulling: the static mesh (stride 11) and the 8-float camera uniform both
/ live in resident storage buffers pulled by gl_VertexIndex; the uniform buffer is
/ overwritten each frame with the orbit-camera pose. uCam=ub[0..3], uPan=ub[4..6].
swVtx: shader.vertexPull[[wNor:`v3;wMat:`v4;wLit:`f32]; {[vb;ub;vid]
  b:11.*vid
  px:vb[b]; py:vb[b+1.]; pz:vb[b+2.]
  nx:vb[b+3.]; ny:vb[b+4.]; nz:vb[b+5.]
  ca:ub[0.]; sa:ub[1.]; xca:ub[2.]; xsa:ub[3.]
  zoom:ub[4.]; cx:ub[5.]; cz:ub[6.]
  c45:0.7071; s45:0.7071; c30:0.8165; s30:0.5774; sc:0.3
  x1:(ca*px)-(sa*pz); z1:(sa*px)+(ca*pz)                   / rotate Y
  y2:(xca*py)-(xsa*z1); z2:(xsa*py)+(xca*z1)               / tilt X
  X:(zoom*x1)-cx; Y:zoom*y2; Z:(zoom*z2)-cz                / zoom + pan
  py0:(c45*X)+(s45*Z); py2:(c45*Z)-(s45*X)
  px1:(c30*Y)-(s30*py2); px2:(s30*Y)+(c30*py2)
  nx1:(ca*nx)-(sa*nz); nz1:(sa*nx)+(ca*nz)                 / rotate normal Y
  ny2:(xca*ny)-(xsa*nz1); nz2:(xsa*ny)+(xca*nz1)           / tilt normal X
  ((sc*py0; sc*px1; 0.5-px2*0.001; 1.0); (nx1;ny2;nz2); (vb[b+6.];vb[b+7.];vb[b+8.];vb[b+9.]); vb[b+10.])
}]

/ ── Global state ──────────────────────────────────────────────────────────────
cam:: CamAt[0.92;0.39;0.97;0.26]                          / start at a 3/4 view
swPipe:: 0; swVB:: 0; swUB:: 0
swN:: (#swStatic) div 11

/ ── Window loop ───────────────────────────────────────────────────────────────
window.run[{[props]
  $[swPipe=0; swPipe:: mesh.compilePull[swVtx; PbrFragment]; 0]
  $[swVB=0;   swVB::   gpu.buffer[swStatic]; 0]           / geometry uploads once
  $[swUB=0;   swUB::   gpu.buffer[8#0.];     0]

  / Fold one frame of input into the orbit camera, then pack its pose as uniforms
  cam:: CamUpdate[cam; props]
  ca: cam`rotCa; sa: cam`rotSa; xca: cam`xCa; xsa: cam`xSa
  zoom: cam`zoom; cx: cam`camX; cz: cam`camZ
  gpu.write[swUB; ca,sa,xca,xsa,zoom,cx,cz,0.]
  mesh.drawPull[swPipe; (swVB;swUB); swN]
}; 0]
